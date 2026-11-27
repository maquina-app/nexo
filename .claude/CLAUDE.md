# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Naming rule (read first — violating this is a bug)

The published gem is `nexo_ai` (RubyGems name — `nexo` was already taken). The Ruby namespace
is `Nexo` — **never** `NexoAi`. The `_ai` suffix is a publication artifact only. Every constant,
class, module, error message, doc, and example uses `Nexo::`. The string `NexoAi` is correct
nowhere — even `spec.name` uses the literal `"nexo_ai"`, not the constant. If you catch yourself
writing `NexoAi` anywhere (`.rb`, `.rbs`, gemspec, docs), stop and fix it to `Nexo`.

File layout that follows from this:
- `lib/nexo_ai.rb` — entry point matching the gem name (so `require "nexo_ai"` works); a
  one-liner that `require_relative "nexo"`.
- `lib/nexo.rb` — the real top-level: `module Nexo`, requires `nexo/version`, defines `Error`.
- `lib/nexo/**/*.rb` — all real code, inside `module Nexo`.
- gemspec: `spec.name = "nexo_ai"` but `spec.version = Nexo::VERSION`.
- README/docs: `gem "nexo_ai"` in Gemfile examples, but `Nexo::Agent`, `Nexo::WorkflowRun`,
  etc. in all code examples.

## What this gem is

An opinionated, drop-in agent harness for [RubyLLM](https://github.com/crmne/ruby_llm)
(`ruby_llm ~> 2.2.0` since 0.13 — see "Verified APIs" below).
Nexo composes the RubyLLM ecosystem into one front door, adding a **Sandbox + Permissions
seam** (pluggable execution env: virtual / local / remote; default `:virtual` + `:read_only`)
and a **WorkflowRun lifecycle** primitive (runId, status, payload, result, event log).

Status: early development, pre-1.0, API unstable. The codebase is currently the freshly
scaffolded skeleton — most of the above is not yet implemented.

## Commands

Local Ruby is 4.0.0 via mise, but the gem targets Ruby 3.3+ (`required_ruby_version >= 3.3.0`).
Keep new code compatible with 3.3.

```bash
bundle install                      # install deps (regenerates the gitignored Gemfile.lock)
bundle exec rake                    # default task: test + standard (run before calling work done)
bundle exec rake test               # tests only
bundle exec ruby -Itest test/test_nexo.rb              # run one test file
bundle exec ruby -Itest test/test_nexo.rb -n test_that_it_has_a_version_number  # one test
bundle exec standardrb              # lint only
bundle exec standardrb --fix        # lint + autofix
gem build nexo_ai.gemspec           # verify the gem packages cleanly
bin/console                         # IRB with the gem loaded
```

## Conventions

- **Linting is StandardRB**, not vanilla RuboCop. `.rubocop.yml` only inherits Standard's
  profile (`inherit_gem: standard`) — do not add bespoke RuboCop cops here; configure via
  Standard if needed. `standard` is a dev dependency in the gemspec.
- **`Gemfile.lock` is gitignored** (library convention) — do not commit it. It is regenerated
  by `bundle install`.
- **`spec.files` is driven by `git ls-files`** in the gemspec. A file must be tracked (or at
  least staged) to be packaged; conversely, a staged-but-deleted path makes `gem build` fail
  with "are not files". Keep the git index consistent with the working tree before building.
- **Tests** are Minitest (`test/test_helper.rb` + `test/*.rb`). `Minitest::TestTask` provides
  the `test` rake task.

### Conventions are owned by agents — don't re-document them

Run these against changed code before calling work done; don't restate their rules here:

- **`rails-simplifier`** — Ruby/Rails structure (37signals / One Person Framework). Run on
  changed `.rb` files.
- **`maquina-ui-standards`** — `maquina_components` UI, forms, Tailwind v4 design tokens. Run on
  changed views/components (`.erb`, `.html`, view helpers, Tailwind).
- **`better-stimulus`** — Stimulus controllers. Run on changed `*_controller.js` Stimulus files.

Match the agent to the file type touched; skip an agent when no file of its type changed.

## Memory & "how does X work?" (Recuerd0 — workspace 62)

- **Always delegate Recuerd0 work to the `recuerd0:remember` agent** — never call the `recuerd0`
  CLI directly.
- **Search before assuming, and before reading code.** Search Recuerd0 (workspace 62) first. Read
  code only if the search comes back empty or code is explicitly requested — then save the
  explanation back as a memory.
- **Capture new decisions, gotchas, and preferences as they emerge.** Before recording, search for
  an existing memory and update it with a new version rather than creating a duplicate.
- **CLAUDE.md vs. Recuerd0 split:** keep here the durable, repo-shaping rules every session needs
  (naming, layout, commands, conventions, the gotchas below). Send to Recuerd0 the longer-form
  "why we decided X", debugging narratives, and discoveries that don't need to load every session.

## Gotchas

- **Test suite forces UTF-8 (Spec 1).** `ruby_llm` reads its bundled `models.json` (UTF-8) with
  `File.read` during model resolution. CI here can start with `Encoding.default_external ==
  US-ASCII`, under which that read raises `Encoding::InvalidByteSequenceError` the moment any test
  builds a chat. `test/test_helper.rb` sets `Encoding.default_external = Encoding::UTF_8` to make the
  suite environment-independent. Don't force this in library code — it's an env property, not a gem
  concern.
- **The suite scripts model replies with `ruby_llm`'s own test helper (0.13).** `test_helper`
  does `require "ruby_llm/test_helper"` + `Minitest::Test.include(RubyLLM::TestHelper)` — but only
  `unless ENV["NEXO_LIVE"] == "1"`, so `test/live_smoke_test.rb` reaches a real provider.
  `stub_replies("text")` scripts a reply; `stub_replies tool_call(:"nexo--tools--read_file", path: "x"), "done"`
  drives a REAL tool call through the real loop (the last reply repeats; the script clears after
  each test). A dummy `openai_api_key` lets chat resolution proceed. `ruby_llm-test` is gone.
  Tool names are the underscored class path: `Nexo::Tools::ReadFile` → `nexo--tools--read_file`.

- **`require "nexo"` loads `ruby_llm`.** Spec 1 added `require "ruby_llm"` to `lib/nexo.rb` so the
  `Nexo::Tools::*` files can subclass `RubyLLM::Tool` when Zeitwerk autoloads them. `ruby_llm` is the
  one hard runtime dep, so this is always available and pulls in no Rails.
- **Zeitwerk two-file entry.** `lib/nexo.rb` calls `Zeitwerk::Loader.for_gem` (roots at `lib/`,
  main file `lib/nexo.rb`) and autoloads `lib/nexo/**` into `Nexo`. Two paths under `lib/` are
  NOT managed constants and must stay ignored, or `for_gem`'s extra-file check warns / Zeitwerk
  tries to define a constant from `nexo_ai.rb`: `loader.ignore("#{__dir__}/nexo_ai.rb")` (the
  require-shim) and `loader.ignore("#{__dir__}/generators")` (Rails loads generators). New runtime code
  just drops into `lib/nexo/<name>.rb` inside `module Nexo` — no `require_relative` needed.
- **`Nexo::WorkflowRun` is Zeitwerk-ignored, not autoloaded (Spec 2).** Its body subclasses
  `::ActiveRecord::Base`, which the plain-Ruby path must never touch. `lib/nexo.rb` does
  `loader.ignore("#{__dir__}/nexo/workflow_run.rb")` (and `.../tasks`) so no autoload is
  registered — `defined?(Nexo::WorkflowRun)` stays false offline and `RunStore.default` picks the
  Memory store. The model is loaded only by `Nexo::Engine`, via `require "nexo/workflow_run"` in an
  **initializer** (NOT `ActiveSupport.on_load(:active_record)`: that hook only fires once AR::Base
  is touched, so `rake nexo:logs` could boot, never load AR, and wrongly fall back to Memory). The
  file body is also `if defined?(::ActiveRecord::Base)`-guarded, so requiring it in a Rails app with
  no AR is a harmless no-op.
- **Don't double-wire engine rake tasks (Spec 2).** `Rails::Engine` already auto-loads
  `lib/tasks/*.rake` into the host app. Also `load`ing the file from a `rake_tasks do … end` block
  defines the task body twice, and Rake runs *both* — `nexo:logs` printed every event twice until the
  redundant block was removed.
- **AR-backed tests run in a separate process (Spec 2).** Loading ActiveRecord into the offline
  suite would flip `RunStore.default` to the AR backend for every other test (and break
  `no_rails_test`). So `test/workflow_run_model_test.rb` shells out (via `Bundler.with_unbundled_env`)
  to `test/support/workflow_run_model_check.rb`, which boots AR + in-memory SQLite and asserts on
  printed OK markers. The Rails generator/migrate/runner path is verified through `test/dummy`
  (a minimal SQLite app sharing the gem's Gemfile). Keep the offline `rake test` AR-free.
- **MemoryStore is a process-wide singleton (Spec 2).** `RunStore.default` builds a fresh
  `RunStore::Memory` per call, so the in-memory runs live in a class-level `Memory.runs` hash (keyed
  by UUID) — otherwise `Workflow.logs(id)` (a later `RunStore.default` call) could never find a run
  created by `Workflow.run`. `Memory.reset!` clears it for test isolation.
- **Skills inject instructions only, read by Nexo's own `Skills::Skill` (Spec 3, reworked 0.13).**
  `lib/nexo/skills/skill.rb` reads `SKILL.md` (YAML front matter + body) and lists `scripts/`,
  `assets/`, `references/`. No gem: `ruby_llm-skills` pins ruby_llm 1.x, and core's
  `RubyLLM::Skill` REJECTS underscore names (`email_triage`) — it enforces the Agent Skills rule
  (lowercase, hyphens, equal to the folder name), which would break every host skill resolved from
  a symbol. `Nexo::Agent#chat` appends `skill.content` via `with_instructions(content, append: true)`
  and does **not** call `chat.with_skills` (that attaches a `load_skill` tool reading host files
  outside the sandbox/permission seam). `Skills.load!` and its `MissingDependencyError` are gone.

- **Loop seam Zeitwerk placement + inflections (Spec 4).** The base class is `lib/nexo/loop.rb` →
  `Nexo::Loop`; the backend lives under `lib/nexo/loops/` → `Nexo::Loops`. Do **not** put
  `class Loop` in `lib/nexo/loops.rb` (that path resolves to `Nexo::Loops` and breaks autoloading).
  `lib/nexo.rb` registers two inflections — `"ruby_llm" => "RubyLLM"` and `"mcp" => "MCP"`.
  `Loops::AgentSDK` was REMOVED in 0.13 (its gem was never published); `Loops::RubyLLM` is the only
  backend shipped.

- **`max_turns` is a HARD cap since 0.13 (was telemetry).** `Loops::RubyLLM#run` calls
  `chat.with_tool_options(rounds: max_turns)` before `ask`; at the limit `ruby_llm` raises
  `RubyLLM::ToolRoundLimitError` (a `StandardError`, not a `RubyLLM::Error`) with every tool call
  answered, so the conversation stays valid. The loop emits `:turn_limit_exceeded` once and
  re-raises. `rounds` counts tool-asking model RESPONSES; the older `count_turn` telemetry counts
  tool CALLS, so its event can fire first under concurrent tool calls. `respond_to?(:with_tool_options)`
  guards chat doubles. `max_turns: nil` removes the cap.

- **`Sandboxes::Remote` is pure delegation, vendor-free (Spec 4).** It wraps any client responding to
  `read`/`write`/`exec`/`close`; `shell → client.exec(cmd, timeout:)` and `glob` parses
  `exec("ls …")[:stdout]`. The client's `exec` must return `{ stdout:, stderr:, status: }` (the
  `Sandbox#shell` contract) — adapting a vendor SDK to that shape is the shim's job. No real
  `Sandboxes::E2B`/`Daytona` classes ship in v1 (vendor APIs unpinned) — only `Remote` + the
  README's documented shim pattern.

- **`Workflow.run` keyword/positional trap (Spec 5).** Spec 2's `run(payload = {})` let callers pass
  the payload as bare keywords (`run(doc_id: 7, text: "x")` → positional Hash). Adding *any* real
  keyword (`buffer_events:`) flips Ruby's parsing: bare `key: val` args now bind to keywords and
  `doc_id`/`text` raise `unknown keyword`. Fix that keeps both forms: `run(payload = nil,
  buffer_events: …, **kwargs)` then `payload ||= kwargs` — an explicit positional Hash wins
  (`run({a: 1}, buffer_events: true)`), otherwise the collected keywords become the payload. The
  `Boom` test subclass that overrides `initialize(run)` must become `initialize(run, **opts)` since
  `Workflow.run` now does `new(run, buffer_events:)`.

- **Async is a SOFT dev-only dep; offload is config-gated (Spec 5).** `async ~> 2.0` is a
  `development_dependency` only (never `add_dependency`) — `require "nexo"` with it absent must not
  raise; `Nexo::Concurrent#require_async!` bare-`require`s it (stub `require` on the instance to
  simulate absence) and rescues stdlib `LoadError` → `MissingDependencyError`. `Sandboxes::Local#offload`
  decides by **`Nexo.config.concurrency == :async`**, NOT `Fiber.scheduler` detection: `:async` →
  worker thread, `:threaded` (default) → inline (zero overhead, byte-for-byte Spec 1). Set the worker
  thread's `report_on_exception = false` so a re-raised path-escape `SecurityError` (via `Thread#value`)
  isn't also dumped to stderr.

- **`Nexo.concurrent` submission-order + fail-fast (Spec 5).** One `Async` reactor, `Async::Semaphore`
  bounds in-flight, `Async::Barrier` coordinates; `results[i] = block.call` (index-assigned, so
  submission order regardless of completion). `barrier.wait` re-raises the first task failure; the
  `ensure barrier&.stop` stops the rest. NEVER rescue-and-ignore inside a `barrier.async` block or
  failures vanish. Tests: `sleep` yields under the reactor so fibers genuinely overlap (peak-counter
  assertion); `stub_replies(*n)` scripts one reply per request for fan-out (the last one
  repeats, so a short script never raises).
- **Artifacts mirror the event path exactly (Spec 7).** `stage`/`artifact`/`run.artifacts`
  reuse the sandbox + WorkflowRun seams — no new deps (ERB is stdlib). `Workflow#sandbox` is a
  **lazy memo** (`@sandbox ||= resolve_sandbox(self.class.sandbox)`), so a data-only workflow
  builds nothing and the Spec 2 hot path (`run`/`initialize`/`emit`/`flush_events!`) is
  byte-for-byte unchanged — never resolve the sandbox there. Artifacts persist **immediately**
  (`push_artifact` + `save_artifacts!`), NOT buffered like events. Memory `Run` struct gained an
  `:artifacts` member (init `artifacts: []` in `create`); the AR model reassigns the array for
  json dirty-tracking (`self.artifacts = (artifacts || []) + [a]`) exactly like `push_event`.
  `Workflow.reconcile_interrupted!` reuses `RunStore.default`'s
  `defined?(::ActiveRecord::Base) && defined?(Nexo::WorkflowRun)` gate and rewrites **only**
  `"running"` → `"interrupted"` (returns the count in both branches). SECURITY: `artifact(from:)`
  runs ERB (arbitrary Ruby) — templates must be trusted developer files, never model/user input.
- **The artifacts generator test must `require "active_record"` (Spec 7).** `ArtifactsGenerator`
  (like `WorkflowsGenerator`) computes its migration timestamp via
  `::ActiveRecord::Migration.next_migration_number`, so `test/generators/artifacts_generator_test.rb`
  requires AR inside its `rails_generators_available` guard. This does NOT flip `RunStore.default`
  to the AR backend for the rest of the offline suite: that also needs `Nexo::WorkflowRun`, which
  stays Zeitwerk-ignored and undefined offline. (`WorkflowsGenerator` has no such test, which is
  why this trap only surfaced now.)

- **`run_agent` is pure glue over the existing seam (Spec 8).** `Workflow#run_agent(prompt,
  max_turns: 25)` reads the `self.agent` macro (reader/writer ivar like `sandbox`/`cwd`), does
  `klass.new(sandbox: sandbox)` so the agent runs in the run's **shared** sandbox (`Agent#resolve_sandbox`
  passes a pre-built `Sandbox` straight through — the agent's own `sandbox` macro is ignored; its
  `permissions`/`skills`/`mcp` still apply), then forwards every `Agent#prompt` loop event via
  `emit(:"agent_#{type}", serializable(type, payload))`. `a.close if a.respond_to?(:close)` runs in
  the `ensure` (guarded so it's safe pre-Spec-6). No new loop — it composes `Loops::RubyLLM`'s
  `before_tool_call`/`after_tool_result` + `:done` seam. The `Workflow.run` lifecycle/failure
  contract is byte-for-byte unchanged; `run_agent` is a plain instance method, no Rails coupling.
- **Loop event payload shapes → the type-aware `serializable` reducer (Spec 8, re-VERIFIED on the
  real loop, ruby_llm 2.2.3).** Never `emit` a raw ruby_llm object (won't round-trip through the AR json column). The
  reducer keys off the event **type** (not object shape): `:tool_call` payload is a
  `RubyLLM::ToolCall` (`#name`, `#arguments` — a Hash; `#to_h`); `:tool_result` payload is the tool's
  **return value** — for Nexo gated tools a bare `String` (successful read) or `{error: msg}` Hash, so
  `ok` is derived from the presence of `error`; `:done` payload is the final `RubyLLM::Message`
  (`#content`). The reducer also accepts plain Hashes (so a spy agent can yield `{name:, args:}` /
  `{ok: true}` without building real ruby_llm objects) and degrades with `to_s` rather than raising —
  observability must never break the run. Group 1 tests use a **real spy agent** (not `Minitest::Mock`)
  that reads the staged file from the shared sandbox and records `close`; core suite stays offline.

- **`:fetch` is a two-lock capability (Spec 9).** `Nexo::Tools::Fetch` (stdlib `net/http` GET) needs
  BOTH the `:fetch` capability (default-denied under `:read_only` like `:shell` — added to the
  `%i[write shell fetch]` set in `authorize!`; `:auto`'s `allow:` gained `:fetch`) AND a host in
  `fetch_allow`. `fetch_allow` alone does NOT grant the capability — it only scopes hosts, so a
  `:read_only` egress agent must pass `Permissions.new(mode: :read_only, allow: %i[read glob fetch])`.
  `apply_fetch` attaches the tool only when `fetch_allow` is non-empty (a default agent gets no fetch
  tool), right after `apply_mcp` so it rides the same `before_tool_call`/`after_tool_result` stream.
  Host matching is **subdomain-aware, not exact** (the tasks.md `@allow_hosts.include?` snippet is
  wrong — spec R3/Q4 wins): `host == entry || host.end_with?(".#{entry}")`, case-insensitive, so
  `example.com` permits `news.example.com` but refuses `notexample.com`/`example.com.evil.org`. The
  private-address SSRF guard (`Resolv.getaddresses` → `IPAddr#loopback?/#private?/#link_local?`) runs
  AFTER the allow-list and is never bypassed (an allow-listed `localhost` still `{error:}`); resolution
  failure fails OPEN to the normal connect path. Return shape differs from `ReadFile`: `{body:}`
  (byteslice to `MAX_BYTES = 200_000`) on success, `{error:}` on any denial/error (never raises into
  the loop). `webmock` is a dev-only Gemfile dep (NOT a gemspec `add_dependency`); the tool is pure
  stdlib. Tests glob the whole suite even with `TEST=…` (Minitest::TestTask), so a single-file run
  still executes every test — check the summary line, not the filename.

- **`Nexo::Session` is a normal autoloaded class — host owns the schema (Spec 10).** Unlike
  `WorkflowRun` (Nexo-owned, Zeitwerk-**ignored**), the session chat model is **host-owned**, so
  `lib/nexo/session.rb` is a plain-Ruby, Zeitwerk-**autoloaded** class — do NOT add it to the
  `loader.ignore(...)` list. It references AR only inside its `durable?` branch and only by the
  configured **String** name (`Nexo.config.session_chat_model`, default `"Chat"`), constantized at
  resume time — so `require "nexo"` stays AR-free. Persistence is ruby_llm's `acts_as_chat`; Nexo
  ships **no** migration/generator for `Chat/Message/ToolCall/Model` (the host runs
  `rails g ruby_llm:install`, which sets `config.use_new_acts_as = true` → the association-based API
  in `active_record/acts_as.rb`, NOT the legacy one). The host adds `agent_name`/`instance_id`
  columns + a **unique composite index** to `chats`; that's the one documented step beyond the
  installer.
- **Session backend guard is TWO-part, like `RunStore` (Spec 10).** `Session#durable?` is
  `defined?(::ActiveRecord::Base) && Object.const_defined?(Nexo.config.session_chat_model)` — NOT AR
  alone. The offline suite LOADS ActiveRecord (the generator tests require it), so an AR-only guard
  would wrongly take the durable path and blow up constantizing `"Chat"`. Checking the host model is
  defined mirrors `RunStore.default`'s `AR && Nexo::WorkflowRun` and keeps the memory fallback robust.
  Corollary: you can't assert `refute defined?(::ActiveRecord::Base)` in the combined suite — assert
  the guard doesn't flip instead (`refute Object.const_defined?(config.session_chat_model)` + memory
  path reused).
- **Instruction idempotency across resumes is `acts_as_chat`'s, not ours (Spec 10, re-VERIFIED
  ruby_llm 2.2.3).** `Agent#chat(base: record)` re-applies `with_instructions(@instructions)` on
  EVERY resume; the persisted-chat `#with_instructions` (default `append: false`) calls
  `replace_persisted_system_instructions`, which **collapses all `role: :system` messages to one** and
  updates it — so the stored thread keeps exactly one system copy no matter how many resumes. Skills
  (`append: true`) re-append after that collapse, so `[instructions, skill1, skill2]` rebuilds
  identically each resume. Verified end-to-end in `test/support/session_model_check.rb`.
- **The reused-chat callback trap (Spec 10).** A `Session` runs `Loops::RubyLLM#run` repeatedly over
  the SAME hydrated chat. ruby_llm's `before_tool_call`/`after_tool_result` **append** callbacks
  (`add_callback`), so naive re-wiring stacks a fresh pair every prompt and fires each event N times
  (and leaks across sessions sharing an in-memory chat). Fix: `wire_observability` flags the chat
  (`@nexo_observed`) and wires once, stashing the current block in `@nexo_on_event` so a later prompt
  observes with its own block. A fresh chat (the default per-prompt path) wires once → byte-for-byte
  the prior behavior, so the existing `loops_ruby_llm_test` FakeChat still passes.
- **Session Rails test shells out, like WorkflowRun (Spec 10, ported to 2.2 in 0.13).**
  `test/session_test.rb` execs `test/support/session_model_check.rb` via `Bundler.with_unbundled_env`.
  ruby_llm 2.x persistence is TWO host models (`Chat` `acts_as_chat`, `Message` `acts_as_message`);
  `Model`/`ToolCall` are ruby_llm's own (`RubyLLM::ActiveRecord::Model`/`ToolCall`, tables
  `ruby_llm_models`/`ruby_llm_tool_calls`), and `config.use_new_acts_as` no longer exists. With no
  railtie the check requires the SAME file list the railtie does, in order (`record … acts_as`), then
  `ActiveRecord::Base.include RubyLLM::ActiveRecord::ActsAs`. The inline schema is the SQLite shape of
  `rails g ruby_llm:install` (chats need `ruby_llm_model_id`, `cancelled`, `claim_token`,
  `claimed_until`; plus `ruby_llm_usages`, `ruby_llm_queued_messages`, `ruby_llm_chat_files`) PLUS
  Nexo's `agent_name`/`instance_id`. `record.model=`, `provider=`, `assume_model_exists=` still work.
  A harmless "Active Storage is not loaded" warning is printed.

- **`ActiveSupport::Notifications` becomes defined in the COMBINED offline suite (Spec 11).** A bare
  `require "nexo_ai"` (or webmock/async/ruby_llm each alone) leaves `::ActiveSupport::
  Notifications` undefined — but running the full `rake test` in one process transitively loads it, so
  `Workflow.execute`/`emit`'s guarded `notify_status`/`notify_event` paths DO fire and read `run.id`.
  Consequence: any run double a test injects (e.g. the Spec 5 `CountingRun` in `workflow_async_test.rb`)
  MUST respond to `:id`, or the notification path raises `NoMethodError`. Real runs always carry id;
  only doubles are at risk. Corollary: a plain-core test asserting "emit is exactly Spec 2" must NOT
  `refute defined?(::ActiveSupport::Notifications)` (flaky/load-order-dependent) — assert the
  *persistence* path (push_event/save_events! per emit) instead, which notify_event never touches.
  `ActiveJob`/`ActiveRecord` stay undefined in the combined suite (only `active_support` leaks in), so
  the `run_later`-without-ActiveJob and durable-store selection tests still take the plain-Ruby branch.

- **Spec 11 Rails-runtime test shells out, like WorkflowRun/Session.** `test/workflow_runtime_rails_test.rb`
  execs `test/support/workflow_runtime_check.rb` via `Bundler.with_unbundled_env` (boots AR + SQLite +
  `active_job` with the `:inline` adapter + a stubbed model). Top-level workflow classes so
  `run.workflow_class.constantize` resolves in `WorkflowJob#perform`; the check `require`s
  `active_support/core_ext/string` for `constantize` and sets `ActiveJob::Base.logger =
  Logger.new(IO::NULL)` to silence the inline job log. It asserts `run_later`→done, sync `run`, a real
  `nexo.workflow.event`/`status` subscriber, scopes/predicates, and `artifact_content`. The plain-Ruby
  guarantees (original nested payload preserved, emit=Spec 2 persistence, `run_later` missing-dep raise)
  live inline in `test/workflow_runtime_test.rb`.

- **The dummy app loads `active_record/railtie` but NOT `active_job/railtie` (Spec 11).** So booting
  `test/dummy` leaves `Nexo::WorkflowJob` undefined (its guarded body needs `::ActiveJob`) while
  `Nexo::TurboBroadcaster` IS defined (guarded on `::ActiveSupport::Notifications`, always present under
  Rails) but does not subscribe (broadcast_events defaults false, and turbo-rails is not a dep). This is
  the correct Rails-optional behavior and proves the `nexo.workflow_job`/`nexo.turbo_broadcaster`
  initializers never crash when their dependency is absent. turbo-rails is NOT a dev dependency —
  `TurboBroadcaster.subscribe!` no-ops without `Turbo::StreamsChannel`, so Turbo mirroring is verified
  only at the notification layer.

- **`Sandboxes::Container` is a normal autoloaded class + daemon-free offline suite (Spec 12).**
  `lib/nexo/sandboxes/container.rb` → `Nexo::Sandboxes::Container` drops beside `virtual.rb`/`local.rb`
  — no `loader.ignore`, no inflection (it's plain Ruby: `require "open3"` + `"timeout"`, no Rails, no
  gem dep; the runtime is a HOST binary). The core suite NEVER touches a daemon: argv construction is
  extracted into pure private methods (`run_argv`, `exec_argv`, `bind_spec`, `guard_path`) that
  `test/sandboxes/container_argv_test.rb` + `test/agent_container_test.rb` assert offline. Live runs
  are `NEXO_LIVE`-gated (`test/sandboxes/container_live_test.rb`), skipped without the binary — so they
  don't run in this repo's CI (no docker/container installed here). Every `Open3` call passes an argv
  **array**, never string-interpolated, so file contents/commands can't break the argv. Missing binary
  → `ConfigurationError` (NOT `MissingDependencyError`, which is gems-only); path escape → `SecurityError`;
  start failure → `Nexo::Error`. `image:` is required (no default image) → the bare `sandbox :docker`
  shorthand (no opts) resolves the `:docker` branch but raises `ConfigurationError` for the missing
  image; the usable form is the options Hash `sandbox :docker, image: "..."`.
- **Container reconnect + Apple parity are VERIFY-before-merge (Spec 12).** No live daemon existed when
  this shipped, so the reconnect commands (`docker ps -aqf name=<name>` inspect-by-name, `docker start`
  restart-if-stopped in `reconnect_existing`) and Apple `container` flag/subcommand parity — especially
  `--network` — are encoded from the reference CLI mapping but NOT confirmed against a running daemon.
  Confirm both before trusting the reconnect path / the `:apple` runtime in production. `reconnect_existing`
  fails OPEN (rescues to nil → falls through to a fresh `run`).
- **Container reconnect is now label-exact + Apple-reconnect raises (Spec 20, supersedes the Spec 12
  reconnect note above).** `run_argv` tags every container `--label nexo.sandbox.id=<name>` right after
  `--name`; reconnect matches by the EXACT `label=` filter via the pure helper `reconnect_argv`
  (`<bin> ps -aqf label=nexo.sandbox.id=<name>`), NOT the old `name=<name>` substring. Result handling:
  0 → nil (fresh run), 1 → `start` + reuse, >1 → **raise `Nexo::Error`** (`ambiguous reconnect: <n>…`);
  rescue is `rescue Nexo::Error; raise; rescue; nil` (fail-open only for daemon/CLI errors — the ambiguity
  raise is never swallowed). Keep-alive is now `tail -f /dev/null` (busybox-portable), NEVER `sleep infinity`.
  `reconnect: true` + `runtime: :apple` **raises `ConfigurationError`** at reconnect time (Apple has no
  live-verified exact `label=` filter — R4/Q4 default posture; `ConfigurationError < Error` so it re-raises
  through the `rescue Nexo::Error` arm). No cross-runtime reattach: the lookup shells the runtime-specific
  `@bin`. Still NO live daemon in this env (Linux, no docker; Apple `container` is macOS-only) — the Apple
  parity table in `docs/sandboxes.md` is recorded **UNVERIFIED**; no Apple divergence was fabricated (spec:
  "no auto-filling from assumptions"). `close`/`rm -f` stays id-based. Offline argv proof:
  `test/sandboxes/container_reconnect_argv_test.rb`; live docker smoke (decoy-excluded):
  `test/sandboxes/container_reconnect_smoke.rb`.
- **Container DSL: the `sandbox` macro now takes keywords (Spec 12).** `sandbox(value = nil, **opts)`
  stores a bare value when `opts` is empty (byte-for-byte the old `:virtual`/`:local`/instance forms),
  else a `{type: value, **opts}` Hash. `resolve_sandbox` gained `:docker`/`:apple`/`Hash` branches, all
  routed through `resolve_sandbox_hash` (single source of the type→runtime map + the `container_cwd`
  default). Container `cwd` defaults to `/workspace` (a CONTAINER path), NEVER the host `@cwd` — the host
  dir enters only via a `binds:` entry.

- **`Workflow.resume` uses `Object.const_get`, NOT `String#constantize` (Spec 13).** The offline core
  suite does NOT load `active_support/core_ext/string`, so `String.method_defined?(:constantize)` is
  **false** offline (verified) — a `constantize`-based resume would blow up in the Memory-store tests.
  `resume` therefore does `Object.const_get(run.workflow_class)` (handles `Foo::Bar` qualified names),
  mirroring `Nexo::Session` (Spec 10). `WorkflowJob#perform` keeps `constantize` — it only runs under
  Rails, where the runtime check `require`s the core_ext. `resume` re-enters `execute` from the top with
  `resume_input:`; only `checkpoint`-guarded work is skipped (it's re-entry, NOT replay — no continuation
  capture).
- **`state` mirrors the Spec 7 `artifacts` seam exactly (Spec 13).** `:state` is a Memory `Run` Struct
  member (init `{}`, `save_state! = nil`); the AR model adds a `json` `state` column + `save_state! =
  save!(touch: false)`. `checkpoint`/`suspend!` read/write **string** keys (AR json objects round-trip
  string-keyed — Group 0 verified in `workflow_run_model_check.rb`), so `store.key?(key)` matches Memory.
  `"__suspend__"` is a RESERVED state key (suspend metadata) — a checkpoint must never use that name.
  `checkpoint` persists **immediately** (like artifacts, not buffered like events).
- **`Suspended` is a non-failure outcome caught BEFORE the generic rescue (Spec 13).** In `Workflow.execute`
  the `rescue Nexo::Workflow::Suspended` sits **above** `rescue => e`, marks `"suspended"` (never
  `"failed"`), merges `__suspend__` metadata, `notify_status`, and **returns the run — never re-raises**.
  The `$!`-aware `ensure`-flush stays verbatim: a suspended run still flushes buffered events and `$!` is
  nil there (the signal is caught, not propagating). `Workflow.run`'s failure contract (raise → `"failed"`
  + re-raise) is byte-for-byte unchanged. Adding `"suspended"` to `WorkflowRun::STATUSES` means the
  `workflow_runtime_check.rb` STATUSES equality assertion must be updated too (it's exact-match).
- **The `nexo:state` migration does NOT hardcode the Rails version (Spec 13).** Unlike the older
  `add_artifacts_*` template (`ActiveRecord::Migration[8.0]`), Spec 13's `add_state_to_nexo_workflow_runs`
  uses `ActiveRecord::Migration[ActiveRecord::Migration.current_version]` (spec R1: "Never hardcode a
  Rails version"). The `state` column is also added to the fresh-install `create_nexo_workflow_runs.rb`
  template, so the model checks (which run that create migration) get `state` without running the additive
  one. `resume_later` carries `[run_id, input]` as ActiveJob args; `WorkflowJob#perform(run_id,
  resume_input = nil)` dispatches to `Workflow.resume` when the second arg is present (nil sentinel =
  original enqueue path, backward compatible).

- **Gating Shell by `supports?` broke three "attaches four tools" tests (Spec 14).** R2 makes
  `Agent#chat` attach `Tools::Shell` only when `@sandbox.supports?(:shell)`. The default sandbox is
  `:virtual` (no shell), so every pre-existing test that built a default/`:virtual` agent and asserted
  all four tools — `agent_test.rb`, `loops_ruby_llm_test.rb`, and the session subprocess check
  `test/support/session_model_check.rb` — had to flip to "three tools, Shell gated out". Directly
  constructed `Tools::Shell` (as in `tools_test.rb`) is unaffected: `Shell#execute` still rescues the
  Virtual `NotImplementedError` into `{error:}`. The base `Sandbox` now ships `#instructions` (nil),
  `#supports?(cap)` (`cap != :shell`), and `#mtime` (nil) as defaults; `Container`'s
  `#instructions`/`#supports?` (already present) only became *live* once the Agent started consuming
  them. `OutputTruncator`/`ReadTracker` are plain Zeitwerk-autoloaded modules (no `require_relative`,
  no `loader.ignore`). The R4 clobber guard is real-FS-only (skipped when `sandbox.mtime` is nil, i.e.
  Virtual, or when no `tracker:` is passed) — the stale *test* forces a distinguishable mtime with
  `File.utime` since `File.mtime` may not catch a same-second external edit (best-effort, per spec).

- **Durable approval bridges `:approve` → `suspend!` on Branch A (Spec 16, re-VERIFIED ruby_llm 2.2.3).**
  On 2.2.3 a tool `execute` exception still PROPAGATES out of `chat.ask`: `Chat#invoke_tool` wraps
  the call in `rescuing_tool`, which hands a `StandardError` to `tool.rescue_with_handler`, and that
  RE-RAISES when no `rescue_from` handler matches (`support/rescuable.rb`). A host registering a
  catch-all `RubyLLM::Tool.rescue_from StandardError` WOULD swallow it. Proven on the real loop in
  `test/real_loop_test.rb`. So `Nexo::ApprovalRequired` (top-level, `< StandardError` like
  `Permissions::Denied` — NOT `< Nexo::Error`) raised by the new `:approve` gate travels out to
  `Workflow#run_agent`, which rescues it, records `"__approval__"` (reserved `state` key, sibling of
  `"__suspend__"`), and `suspend!`s. `resume(approved: …)` threads the decision via `Agent.new(decision:)`
  → `resolve_permissions(decision:)` → `Permissions#decision`. `:approve` reuses the Spec 14 `@ask_when`
  predicate (aliased `approve_when:`) — one predicate, not two. Undecided ⇒ suspend; `approved: false`
  ⇒ `Denied` ⇒ tool `{error:}` ⇒ run still `"done"`, effect skipped. **`fetch.rb` was the one tool with
  a broad `rescue => e` (`fetch.rb:58`) that would swallow the signal** — added `rescue
  Nexo::ApprovalRequired; raise` before it; the other four tools rescue narrowly. `:read_only`/`:auto`/
  `:ask`/`authorize_mcp!` are byte-for-byte untouched. Use `with_decision` (non-mutating dup) when
  threading a decision into a user-supplied, class-level `:approve` `Permissions` so the shared instance
  isn't clobbered.

- **Docs live in `docs/` + RDoc; the README is a slim index (Spec 17).** The 1394-line README was split
  into 13 topic guides under `docs/` (getting-started, sandboxes, permissions, tools, loops, workflows,
  durable-workflows, skills, mcp, web, sessions, rails, concurrency); prose was MOVED verbatim (safety
  caveats preserved — there's a caveat grep in the spec). `Rakefile` gained `require "rdoc/task"` +
  `RDoc::Task.new(:doc)` (rd.rdoc_dir `doc`, gitignored). Naming the task `:doc` yields BOTH `rake doc`
  (build) AND `rake doc:coverage` for free — RDoc's own coverage subtask, which runs
  `RDoc::RDoc.new.document(["-C", …])`; verified rdoc 8.0.0 that call `exit(1)`s on <100% (SystemExit
  propagates → the Rake task fails), so it's a real CI gate with NO bespoke parser (rule #1: compose,
  don't reimplement). Do NOT copy the spec's hand-written `%x{rdoc -C}` parser — the built-in task is the
  native path. **`default: %i[test standard]` is unchanged** — `doc`/`doc:coverage` are never in the test
  run. `.document` (tracked: `README.md`, `docs`, `lib`) + `spec.metadata["documentation_uri"]` make
  rubydoc.info render the guides. CI got a dedicated `docs` job.
- **RDoc HTML generation needs UTF-8 external encoding (Spec 17).** The README/guides carry UTF-8 glyphs
  (⚠️, em dashes); RDoc reads them with `Encoding.default_external`, and CI here can start US-ASCII →
  `error generating index.html: "\xF0" on US-ASCII (Encoding::InvalidByteSequenceError)`. The `Rakefile`
  pins `Encoding.default_external = Encoding::UTF_8 if … == US_ASCII` at load (same trick as
  `test_helper`). `--encoding UTF-8` alone does NOT fix HTML generation (it only sets the *parse*
  encoding) — the default_external pin is required. The coverage report (`-C`, no HTML) tolerates
  `--encoding UTF-8` but the pin covers it too.
- **R3 `{…}` cross-ref normalization is comment-only + non-semantic (Spec 17).** Under RDoc, bare
  `Nexo::Foo`, `Foo#method`, `#method` (current class), and `::classmethod` AUTO-LINK; `{Nexo::Foo}`
  renders literal braces and bare `.method` does NOT link. So the pass strips braces to the bare form,
  mapping `{#m}` → `#m` and `{.m}` → `::m` (class-method form, since `.m` won't link). ONLY comment lines
  are touched — `#{Nexo::VERSION}` / `#{Nexo.generate_run_id}` string interpolations in CODE are left, so
  the spec's counter `grep -rEc "\{[A-Z]…\}" lib` bottoms out at 2 (those interpolations), NOT 0; the
  comment cross-ref count IS 0. Every lib `.rb` diff is comment-only (verified: no non-comment line
  changed), so `rake test` is untouched.
- **All doc comments are Markdown, not RDoc markup (project-wide `markup: markdown`).** `.rdoc_options`
  (tracked, so `gem rdoc`/rubydoc.info honor it) and `rd.markup = "markdown"` in the `Rakefile` switch
  every `lib/**/*.rb` comment to RDoc's Markdown parser. Write `` `code` `` (never `+code+`/`<tt>`),
  `## Heading` (never `== Heading`), and fenced ```` ```ruby ```` / ```` ```sh ```` blocks for samples
  (never the 2-space-indented RDoc verbatim form — under Markdown it renders as a plain paragraph).
  Cross-refs still auto-link inside code spans (`` `Nexo::Foo` ``, `` `#prompt` `` → linked `<code>`),
  verified against rdoc 7.2.0. A `+…+` span must not wrap across comment lines and a comment line must
  not start with `+ ` (Markdown reads it as a list bullet). No YARD tags (`@return`, `@param`) — RDoc
  renders them as literal text. Relative links from `docs/*.md` to `examples/*` are rewritten by RDoc to
  `…_rb.html` pages that don't exist in the site, so guides link examples by GitHub blob URL instead.

## Verified APIs (ruby_llm 2.2.3 — the 0.13 port)

Read from the installed gem source and proven through `test/real_loop_test.rb`. The 1.16 facts
this replaces are gone; do not trust memory of the 1.x API.

- **Tool DSL.** `parameter :name, type:, required:, description:` and `description "…"`.
  `param`/`desc:`/`params` are REMOVED (NoMethodError at class load). Body is `#execute(**kw)`.
- **The loop calls tools with keywords:** `tool.call(**arguments, tool_call:)`. `Tool#call` strips
  `tool_call:` unless `execute` declares it. A wrapper must define `call(**arguments)`.
- **`chat.tools`** is a Hash keyed by tool-name Symbol — but it is DERIVED on each call
  (`@tools.reject…` plus built-ins and MCP tools), so mutating it (`transform_values!`) changes
  nothing. Use `Agent#wrap_mcp_tool` to decorate.
- **`with_tools` does not type-check.** It needs `qualified_name`, `namespace`, `name`,
  `deferred?`; rendering needs `description`/`parameters_schema`. A `method_missing` delegator
  (`MCP::GatedTool`) is accepted. Execution settings moved off it: `with_tool_options(choice:,
  calls:, concurrency:, workers:, rounds:)`; `chat.concurrency` is still a reader.
- **Callbacks are additive.** `before_tool_call { |tool_call| }` gets a `RubyLLM::ToolCall`
  (`name`, `arguments` — a Hash with SYMBOL keys now); `after_tool_result { |result| }` gets the
  tool's raw return value. `on_tool_call`/`on_tool_result` are gone.
- **`around_tool_call { |tool_call, &run| }` is a backstop, not the gate (0.14, read from
  `chat.rb:2791-2817`).** Not calling `run` gives the model the FIXED
  `{error: "The <name> call did not run."}`; the block's return value is ignored, so a denial
  message cannot travel through it. A raise in the block leaves `chat.ask`. It wraps every
  LOCAL tool (MCP, `run_code`, file-store tools, skill loader), not provider-side ones, and runs
  after core's own approval decision, on the tool's thread under tool concurrency. Blocks nest,
  first registered outermost. `Agent#apply_tool_backstop` registers ONE per chat (guarded by
  `@nexo_backstop`, names in `@nexo_known_tools`) — do not move `authorize!` into it.
- **MCP is core.** `RubyLLM.mcp(name:, url: | command: [argv], env:, directory:, headers:,
  bearer_token:, timeout:)` returns a `RubyLLM::MCP` instance; unknown settings raise
  `ArgumentError`. Nothing connects until the first request. `server.tools` → Array of
  `RubyLLM::MCP::Tool` (a `RubyLLM::Tool` subclass, `call(**arguments)`); teardown is `#close`
  (not `#stop`). A Proc `bearer_token`/header is resolved per request via `instance_exec`. A stdio
  process inherits only `Stdio::INHERITED_ENV` and its stderr is the parent's. The community
  `ruby_llm-mcp` gem defines the same constant and must not be bundled.
- **Nexo attaches MCP tools with `with_tools`, NOT `chat.with_mcp(server)`** — `with_mcp` offers the
  server's tools straight from `mcp.reachable_tools`, with no place to insert the gate.
- **Core approvals are durable only with `acts_as_chat` (0.14 decision).** `requires_approval`
  / `pending_questions` / `chat.waiting?` keep their state in `Chat::ToolCallState`, which is
  NOT part of `messages` — rebuilding a chat loses it. Nexo workflows keep no chat and resume
  by re-running, so `:approve` stays on `ApprovalRequired` → `suspend!`. Do not port it.
- **`RubyLLM.workflow(name, id:) { |wf| }` is instrumentation only** (Fiber-storage context,
  events `workflow.ruby_llm` / `workflow_step.ruby_llm`, `wf.step(name) { }`). An empty name
  raises `ArgumentError`, hence `name || "Nexo::Workflow"` in `Workflow.execute`. Exceptions
  (incl. `Suspended`) pass through. Tests observe it via `RubyLLM.config.instrumenter`.
- **Sandbox contract** (`ruby_llm/sandbox.rb`): `supported?` + `run(*command, timeout:,
  readable:, writable:, denied:, directory:, env:, network:)` → `stdout`/`stderr`/`exit_code`/
  `timed_out?`. `RubyLLM::Sandbox.resolve(MXC::Sandbox.new)` (a `:nodoc:` method) builds the
  adapter; `mxc` >= 0.4.1 is an OPTIONAL gem. It covers command execution only — no file API.
- **Tool results.** A Hash/Array return reaches the model as JSON text (was Ruby `inspect`).
  Malformed arguments and unknown tool names become `{error:}` results without running anything.
- **`with_instructions(text, append: true)`** still appends; default replaces.
- **Not re-verified on 2.2:** the "Faraday `:net_http` yields under the fiber scheduler" claim from
  Spec 5 (the connection class moved to `RubyLLM::Transport::Connection`). `nexo-mail` runs its
  source agents under an Async reactor on 2.2.3 without change, which is the practical evidence.
- **Offload primitive = `Thread.new(&block).value`** (Spec 5, unchanged — an `async` fact, not a
  ruby_llm one).

## More gotchas

- **0.15 composes six ruby_llm 2.2 pieces; all read from source, each proven as noted.**
  - `with_tool_options(calls: N)` caps calls PER RESPONSE (N >= 2; `1`/`:one` means "ask the
    provider for one"), not per prompt. `Nexo.config.tool_calls_per_round` (default 20).
    `chat.tool_options[:calls]` reads it back. `stub_replies` cannot script a multi-call
    response, so the cap itself is asserted on the chat, not through the loop.
  - `with_context_budget(per_result:, per_request:, window:)` needs a known context window;
    without one it does nothing and warns once. That is why the `context_budget` macro has
    NO default — an Ollama/`assume_model_exists` model would warn on every chat.
  - **MCP OAuth**: `RubyLLM.mcp(..., oauth: {...})` works inline; the owner is resolved by
    `instance_exec` on the MCP instance, so Nexo passes `owner: -> { owner }`. Credentials are
    filed under `"<owner.to_gid || owner.to_s>@<server url>"` in
    `RubyLLM.config.mcp_credential_store` (contract: `read(key)`, `write(key, data, owner:)`,
    `delete(key)`, optional `synchronize(key)`). `server.authorized?` reads the store only —
    no network — which is what `Agent#require_mcp_authorization!` relies on. NOT run against
    a live authorization server.
  - **Core file tools are attached with `with_tools`, never `chat.with_file_store`** (same
    reason as MCP: no place for the gate). `RubyLLM::FileStore::Tools.classes([:read])` etc.
    and the tools' `new(store: -> { store })` are `:nodoc:` internals. Tool names are bare:
    `read_file`, `list_files`, `search_files` (param `query`), `write_file`, `edit_file`
    (`path`/`old_text`/`new_text`, or `edits:` naming several paths — hence the GatedTool
    `detail:` falls back to the whole call when there is no `path`, or one approval would
    cover every multi-file edit).
  - `SandboxFileStore#list` gives `digest: nil` on purpose (no read per file); `[]` computes
    it. The read-before-write guard lives in `FileStore`'s in-memory `@reads`, so ONE store
    per chat.
  - `ContainerRunner` is NOT a `Nexo::Sandbox`; it is the sandbox contract only. Binds granted
    paths at their own host path. VERIFIED live on Docker 29/OrbStack as `Local`'s isolation.
- **Use `Sandboxes::Subprocess.capture`, never `Timeout.timeout { Open3.capture3 }`** for a
  command that must stop. `Container#exec!` still uses the old form (its timeout does not
  kill the `docker exec`); left for a later pass.
- **Docker is OrbStack on this machine and is usually STOPPED** (`orbctl start`). Live
  container tests: `NEXO_LIVE=1 ... test/sandboxes/container_live_test.rb`,
  `container_reconnect_smoke.rb`, `container_runner_test.rb`. All pass as of 0.15.

- **`Sandboxes::Local#shell` uses `Process.spawn`, not Open3 (0.14).** Two bugs lived in the old
  `Timeout.timeout { Open3.capture3(@env, cmd) }`: (1) an env Hash passed to spawn is MERGED
  into the parent's environment unless `unsetenv_others: true`, so the "narrowed ENV" never
  narrowed anything; (2) Open3's block form joins the wait thread in its `ensure`, so the
  timeout fired only after the child exited by itself. Now: `pgroup: true` +
  `unsetenv_others: true`, readers on threads, `Process.kill("KILL", -pid)` on timeout. Do not
  "simplify" it back to capture3.
- **Confined shell (0.14) is opt-in and never falls back.** `isolation: :confined` → mxc via
  `ruby_llm`'s adapter; unsupported machine ⇒ `ConfigurationError` on first `shell`, missing gem
  ⇒ `MissingDependencyError`. VERIFIED macOS/Seatbelt, mxc 0.4.1: outside write, home read and
  network refused; env is clean; `ruby` starts but cannot load RubyGems unless its prefix is in
  `readable:` (that is why `:confined` is not the default). Linux/Bubblewrap VERIFIED in CI since 0.15 (the two confined tests run there: same skip count as macOS).
  `mxc` is a Gemfile dev dep only; the one live test skips without it.
- **Approvals are per call (0.14).** `Workflow#record_approval!` files `resume_input[:approved]`
  under `Permissions.approval_key(capability, detail, args)` in the reserved `"__approvals__"`
  state key and clears `"__approval__"`; `run_agent` passes the map as `Agent.new(decisions:)`.
  A custom agent class used with `run_agent` must accept `decisions:` (not `decision:`).
  `Permissions#decision` (global) remains only for direct callers; `decisions` wins when both
  are set. Keys stringify and sort argument keys so they survive a JSON run store.
- **Host tools go through the `tools` macro (0.14).** `tools Foo, capability: :write` wraps in
  `Nexo::GatedTool` (`MCP::GatedTool` is its subclass, authorizing by name). A tool attached by
  overriding `#chat` AFTER `super` is unknown to the backstop: warned once
  (`Nexo.warn_undeclared_tool`), refused under `Nexo.config.strict_tools`. Tests asserting on
  stderr must match the message, not `assert_empty` — `-w` leaks unrelated ruby_llm warnings.
- **MCP schema shaping (0.14).** `Permissions#never_allows_mcp?` drops MCP tools `:read_only`
  cannot authorize. Tests that expect an MCP tool attached must list it in `mcp_allow`.
- **`fetch.rb` and `web_search.rb` BOTH have a broad `rescue => e`** and both re-raise
  `ApprovalRequired` first; the other four tools rescue narrowly. (An older note above names
  only `fetch.rb:58`.)

- **Spec 21 scheduling tests load ActiveJob IN-PROCESS (not a subprocess).** Unlike the Spec 11/13
  Rails-runtime tests (which shell out via `Bundler.with_unbundled_env` because they need
  ActiveRecord, whose load flips `RunStore.default` to the AR backend), `test/workflow_scheduled_
  resume_test.rb` and `test/workflow_scheduled_checkpoint_integration_test.rb` just
  `require "active_job"` + `require "nexo/workflow_job"` at the top and use the `:test` adapter
  in-process. This is safe because `active_job` pulls in **neither `active_record` nor
  `Rails::Engine`** — so `RunStore.default` stays the Memory store (the AR gate needs `ActiveRecord::
  Base` AND `Nexo::WorkflowRun`, both still absent) and `no_rails_test.rb`'s `refute defined?(::Rails::
  Engine)` still holds. The one consequence: `workflow_runtime_test.rb`'s
  `test_run_later_without_active_job_raises_missing_dependency` now **skips** in the combined suite
  (its `skip if defined?(::ActiveJob)` guard trips) — its ActiveJob-present coverage lives in the
  `workflow_runtime_check.rb` subprocess. Since `rake test` loads every `test/*.rb` into one process,
  requiring `active_job` in any file makes it process-wide; that's intended here.
- **`checkpoint_all` is deliberately UN-rate-bounded (Spec 21 R2.4).** It calls
  `Nexo.concurrent(max_in_flight: pending.size)` — every pending step in flight at once, NOT capped
  at `config.max_in_flight`. This looks like it defeats `Nexo.concurrent`'s rate-bound raison d'être,
  and a simplifier pass will flag it; it is a spec mandate ("no new rate-limiting knob; callers bound
  the batch by how many keys they pass"). Do not "fix" it to inherit the config cap. Each step
  persists as it completes via `#persist_checkpoint` (Mutex-guarded read→merge→assign→`save_state!`,
  with the `emit(:checkpoint, name:)` inside the same `synchronize` so event appends serialize) — so
  a partial-batch failure leaves completed steps persisted and a retry re-runs only the missing ones
  (NOT atomic — documented "Known trade-off").

## Repo

`origin` → `git@github.com:maquina-app/nexo.git` (note: repo is `nexo`, gem is `nexo_ai`).
Conventional Commits (`chore:`, `feat:`, etc.). Default branch `main`.
