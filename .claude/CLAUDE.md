# CLAUDE.md

Nexo (`nexo_ai`): an agent harness over `ruby_llm ~> 2.2.0`. It adds a Sandbox + Permissions
seam and a durable WorkflowRun lifecycle. Pre-1.0, released through 0.16.

## Naming rule (violating this is a bug)

Gem name `nexo_ai`; Ruby namespace `Nexo` — **never** `NexoAi`, anywhere (`.rb`, `.rbs`,
gemspec, docs). `spec.name = "nexo_ai"`, `spec.version = Nexo::VERSION`. Docs say
`gem "nexo_ai"` in Gemfiles and `Nexo::Agent` in code.

## Commands

Ruby 4.0 locally through mise; the gem targets 3.3+, so keep new code 3.3-compatible.

```bash
mise exec -- bundle install
mise exec -- bundle exec rake               # test + standard — run before calling work done
mise exec -- bundle exec rake doc:coverage  # must stay 100% (CI gate)
mise exec -- bundle exec ruby -Itest test/agent_test.rb -n test_name
mise exec -- gem build nexo_ai.gemspec      # spec.files is `git ls-files`: stage new files first
```

- This shell sets `RUBYOPT=-W0`: `Kernel#warn` prints nothing in a single-file run. Nexo's own
  notices go through `Nexo.notice` (`$stderr.write`) for that reason — do not change them to `warn`.
- `rake test` loads every `test/*.rb` in one process even with `TEST=…`; read the summary line.
- `Gemfile.lock` is gitignored. Lint is StandardRB only; add no RuboCop cops.
- Conventional Commits. `origin` is `maquina-app/nexo` (repo `nexo`, gem `nexo_ai`).

## Conventions are owned by skills

Run `rails-simplifier:simplify` (Skill tool, not an agent) over changed `lib/**/*.rb` before
calling work done. `maquina-ui-standards:ui` and `better-stimulus:better-stimulus` apply only
if a view or Stimulus file changes (rare here).

## Memory (Recuerd0, workspace 62)

- Recuerd0 work goes through a `general-purpose` agent told to call the `recuerd0:remember`
  Skill first. Never call the `recuerd0` CLI directly.
- Search it before reading code for a "how does X work / why" question. The spec-by-spec
  history that used to live in this file is there ("Nexo internals: …").
- This file keeps rules a session needs every time; send narratives and decisions to Recuerd0.

## Layout and loading

- `lib/nexo_ai.rb` is a one-line shim; `lib/nexo.rb` is the real entry and requires `ruby_llm`.
- Zeitwerk `for_gem`. Ignored, and must stay ignored: `nexo_ai.rb`, `generators/`, `nexo/tasks`,
  and `nexo/workflow_run.rb` (subclasses `ActiveRecord::Base`; loaded only by `Nexo::Engine` in
  an initializer, never `on_load(:active_record)`).
- Inflections: `ruby_llm` → `RubyLLM`, `mcp` → `MCP`. Name new files so the default inflection
  works (`model_options.rb`, not `llm_options.rb`).
- `lib/nexo/loop.rb` is `Nexo::Loop`; backends are under `lib/nexo/loops/`. Never define
  `Loop` in `loops.rb`.
- `Nexo::Session` is a normal autoloaded class (host owns the chat schema); it touches
  ActiveRecord only inside `durable?`, by the configured String name.
- Do not `load` engine rake tasks from a `rake_tasks` block: Rails already loads them and the
  task would run twice.

## Security invariants — do not "simplify" these away

- **The gate lives in the tool.** `Permissions#authorize!` runs inside each Nexo tool and
  inside `GatedTool`. `around_tool_call` is only a fail-closed backstop: a skipped call can
  carry nothing but ruby_llm's fixed "did not run" text. Never move `authorize!` into it.
- **Attach with `with_tools`, never `chat.with_mcp` or `chat.with_file_store`.** Those attach
  tools with no place for the gate. Same reason `provider_tools`, `file_store` and
  `code_execution` are refused inside an `llm` block.
- **`strict_tools` is on by default (0.16).** A tool a host added after `super` in `#chat` is
  refused. A name not on the chat at all is passed through, so ruby_llm answers "no tool named".
- **Shell commands run through `Sandboxes::Subprocess.capture`** (`Process.spawn`,
  `pgroup: true`, `unsetenv_others: true`, group killed on timeout). Never
  `Timeout.timeout { Open3.capture3 }`: it neither narrows the environment nor stops the child.
- **A container exec carries a `NEXO_EXEC` marker** and a timeout kills every process in the
  container that has it; killing the runtime's client alone leaves the command running.
- Every runtime command is an argv array, never an interpolated shell string. A model-supplied
  pattern or marker is passed as `$1`.
- Confined shell (`isolation: :confined`) never falls back: unsupported machine ⇒
  `ConfigurationError`, missing `mxc` gem ⇒ `MissingDependencyError`.
- Skills inject instructions only. `Agent#chat` never calls `chat.with_skills`.
- `artifact(from:)` renders ERB: templates are trusted developer files, never model output.
- `:fetch` needs two locks: the `:fetch` capability **and** a host in `fetch_allow`
  (subdomain-aware suffix match). The private-address guard runs after the allow-list and is
  never bypassed. `fetch.rb` and `web_search.rb` have a broad `rescue`; both re-raise
  `ApprovalRequired` first — keep that.
- `Nexo::ApprovalRequired` and `Permissions::Denied` are `StandardError`, not `Nexo::Error`.
  Approval reaches `Workflow#run_agent` only because ruby_llm re-raises a tool exception when no
  `rescue_from` matches. A host's catch-all `RubyLLM::Tool.rescue_from StandardError` breaks it.
- Approvals are per call: `Permissions.approval_key`, reserved state key `"__approvals__"`.
  A custom agent class used with `run_agent` must accept `decisions:` (and `mcp_owner:` if used).
- MCP OAuth credentials: `CredentialStore.new(dir:, key:)` encrypts; without `key:` they are
  plain JSON `0600`. Never log a token.

## Verified APIs (ruby_llm 2.2.3 — read from source, proven in `test/real_loop_test.rb`)

Do not trust memory of the 1.x API.

- Tool DSL: `parameter :name, type:, required:, description:`, `description "…"`, body
  `#execute(**kw)`. `param`/`desc:` are gone. The loop calls `tool.call(**arguments, tool_call:)`.
- `chat.tools` is a Hash by qualified-name Symbol, **derived on each call** — mutating it does
  nothing. It raises `ArgumentError` on two tools with one name.
- Tool names: a Nexo tool is its underscored class path (`nexo--tools--shell`); ruby_llm's file
  tools and MCP tools are bare (`read_file`). That is why an MCP `read_file` clashes with the
  default file tools — `Agent#refuse_mcp_name_clash!`, way out `file_tools :none`.
- `with_tools` does not type-check: it needs `qualified_name`, `namespace`, `name`,
  `deferred?`, plus `description`/`parameters_schema`. Execution settings are
  `with_tool_options(choice:, calls:, concurrency:, workers:, rounds:)`.
- `max_turns` → `rounds:`; at the limit ruby_llm raises `RubyLLM::ToolRoundLimitError` (a
  `StandardError`). `calls: N` caps calls per response (N ≥ 2).
- Callbacks are additive: `before_tool_call { |tool_call| }` (arguments have Symbol keys),
  `after_tool_result { |result| }` (raw return value). A reused chat must be wired once
  (`@nexo_observed`, `@nexo_backstop`), or events fire N times.
- A tool result: Nexo tools return a String or `{error:}`; ruby_llm's file tools a String; an
  MCP tool a `RubyLLM::MCP::Result` (`#text`, `#error?` — its `to_s` is an object address).
- `with_instructions(text, append: true)` appends; the default replaces, and on a persisted
  chat collapses all system messages to one.
- `RubyLLM::Agent`: `Klass.chat(**opts)` forwards to `RubyLLM.chat` and applies declarations;
  `Klass.new(chat: existing, persist_instructions: false)` applies them onto an existing chat or
  record and leaves messages and tools alone. Used by `Agent#build_chat` for the `llm` block.
  Inheriting from it was declined twice (one eager chat per instance; five macro name clashes).
- MCP: `RubyLLM.mcp(name:, url: | command: [argv], …)`; nothing connects until the first
  request; `server.tools`; teardown is `#close`. The community `ruby_llm-mcp` gem must not be
  bundled.
- MCP OAuth: owner resolved by `instance_exec`, so Nexo passes `owner: -> { owner }`.
  `server.authorized?` reads the store only. Client identity is dynamic registration, a given
  `client_id`, or `RubyLLM.config.mcp_client_id` (a Client ID Metadata Document URL) — a server
  with neither registration nor that config fails with "does not register clients". Loopback
  `http` is allowed only when the server itself is loopback.
- Core approvals (`requires_approval`, `pending_questions`) are durable only with
  `acts_as_chat`; Nexo keeps `:approve` on `ApprovalRequired` → `suspend!`. Do not port it.
- `RubyLLM.workflow(name, id:)` is instrumentation only; an empty name raises.
- Sandbox contract: `supported?` + `run(*command, timeout:, readable:, writable:, denied:,
  directory:, env:, network:)` → `stdout`/`stderr`/`exit_code`/`timed_out?`. `ContainerRunner`
  answers it; it is not a `Nexo::Sandbox`.
- `with_context_budget` needs a known context window, so the macro has no default.
- `FileStore::Tools.classes([...])` and the tools' `new(store: -> { store })` are `:nodoc:`
  internals; one `SandboxFileStore` per chat (the read-before-write guard is in memory).
- Persistence is two host models (`Chat` `acts_as_chat`, `Message` `acts_as_message`);
  `config.use_new_acts_as` no longer exists.

## Workflow rules

- `Workflow.run(payload = nil, buffer_events:, **kwargs)` then `payload ||= kwargs`: keep both
  call forms working when adding a keyword.
- State keys are Strings. Reserved: `__suspend__`, `__approval__`, `__approvals__`,
  `__buffer_events__`. Checkpoints and artifacts persist immediately; events may be buffered.
- `rescue Workflow::Suspended` sits above the generic rescue and never re-raises.
- `resume` (suspended) and `retry` (failed, interrupted) re-enter `#call` from the top; only
  checkpointed work is skipped. Both use `Object.const_get`, not `constantize`.
- `claim_for_resume!(run, from:)` is the compare-and-set on all three run stores.
- `reconcile_interrupted!` goes through `RunStore.default` and is **not a liveness check** —
  it marks every `"running"` run, including one alive in another process.
- `checkpoint_all` is deliberately not rate-bounded (`max_in_flight: pending.size`) and not
  atomic. Do not "fix" it to the config cap.
- `Workflow#sandbox` is a lazy memo; never resolve it in `run`/`initialize`/`emit`.
- Never `emit` a raw ruby_llm object: go through `serializable(type, payload)`.
- Migrations use `ActiveRecord::Migration[ActiveRecord::Migration.current_version]`.

## Test rules

- Tests are Minitest, seams and real doubles, no mocks of the loop. `stub_replies` scripts the
  model; `stub_replies tool_call(:read_file, path: "x"), "done"` drives a real tool call. It
  cannot script a multi-call response.
- The offline suite stays ActiveRecord-backend-free and daemon-free. AR-backed checks shell out
  with `Bundler.with_unbundled_env` to `test/support/*_check.rb` and assert on printed `_OK`
  markers. `active_job` may be required in-process; `active_record` may be loaded only where
  `Nexo::WorkflowRun` stays undefined.
- Never assert `refute defined?(::ActiveRecord::Base)` or `…Notifications` in the combined
  suite (load-order dependent). A run double must respond to `:id`.
- Assertions on stderr match the message; never `assert_empty err`.
- `Memory` run store is a process-wide table: `Nexo::RunStore::Memory.reset!` in setup.
- A test that expects an MCP tool attached must list it in `mcp_allow`.
- A test that needs real HTTP on 127.0.0.1 must
  `WebMock.disable_net_connect!(allow_localhost: true)` (WebMock is loaded suite-wide by
  `tools_fetch_test`) and restore it in teardown.
- Live tests are `NEXO_LIVE=1`-gated and skip without the binary:
  `test/sandboxes/container_live_test.rb`, `container_reconnect_smoke.rb`,
  `container_runner_test.rb` (`NEXO_CONTAINER_RUNTIME=apple` for Apple), `live_smoke_test.rb`.

## This machine

- Docker is OrbStack and usually stopped: `orbctl start` / `orbctl stop`.
- Apple `container` 1.7.1 is installed (Homebrew): `container system start` /
  `container system stop`. On it `--security-opt` and `--pids-limit` are rejected, a `--tmpfs`
  under `--read-only` is writable, and there is no label filter (list JSON, compare in Ruby).
- `mxc` is installed (Gemfile dev dependency), so the confined-shell tests run here.

## Docs

- Guides are in `docs/`; the README is an index. Doc comments are **Markdown** (`` `code` ``,
  fenced blocks), not RDoc markup, and carry no YARD tags. Cross-references are bare
  (`Nexo::Foo`, `#method`, `::class_method`), never `{Nexo::Foo}`.
- A doc comment must sit directly above what it documents; inserting a method between a
  comment and its target drops coverage.
- Link examples from guides by GitHub blob URL, not a relative path.
- `Rakefile` pins `Encoding.default_external` to UTF-8 for RDoc; `test_helper` does the same
  for the suite. Do not force it in library code.

## Not verified

- A sign-in against a third-party OAuth MCP server (the flow is verified over real HTTP
  against a local server; discovery against `getliminal.app/mcp` works). Not pursued: that
  server takes only a Client ID Metadata Document, which the host application serves, not Nexo.
- "Faraday yields under the fiber scheduler" on 2.2 (practical evidence only: `nexo-mail`).
