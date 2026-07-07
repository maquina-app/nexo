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

An opinionated, drop-in agent harness for [RubyLLM](https://github.com/crmne/ruby_llm).
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
- **`ruby_llm-test` needs `delegate` + is gated off for live smoke (Spec 1).** `ruby_llm-test`
  0.2.0's `TestProvider` references `SimpleDelegator` without requiring stdlib `delegate`, so
  `test_helper` does `require "delegate"` first. It then prepends `ResolveWithTestProvider` (the
  fake provider) — but only `unless ENV["NEXO_LIVE"] == "1"`, so `test/live_smoke_test.rb` reaches a
  real provider. A dummy `openai_api_key` is configured so chat resolution never needs credentials.
- **Verified `ruby_llm` 1.16 APIs (Spec 1).** Tool body method is `#execute` (`#call` dispatches to
  it); attach tool instances with `chat.with_tools(*instances)` (stored in `chat.tools`, a Hash
  keyed by tool-name symbol); set system prompt with `chat.with_instructions`. `Open3.capture3` has
  no `timeout:` kwarg on this Ruby, so `Sandboxes::Local#shell` wraps it in `Timeout.timeout`.
- **`require "nexo"` loads `ruby_llm`.** Spec 1 added `require "ruby_llm"` to `lib/nexo.rb` so the
  `Nexo::Tools::*` files can subclass `RubyLLM::Tool` when Zeitwerk autoloads them. `ruby_llm` is the
  one hard runtime dep, so this is always available and pulls in no Rails.
- **Zeitwerk two-file entry.** `lib/nexo.rb` calls `Zeitwerk::Loader.for_gem` (roots at `lib/`,
  main file `lib/nexo.rb`) and autoloads `lib/nexo/**` into `Nexo`. Two paths under `lib/` are
  NOT managed constants and must stay ignored, or `for_gem`'s extra-file check warns / Zeitwerk
  tries to define a constant from `nexo_ai.rb`: `loader.ignore("#{__dir__}/nexo_ai.rb")` (the
  require-shim) and `loader.ignore("#{__dir__}/generators")` (Rails loads generators). The
  `agent_sdk => AgentSDK` inflection is registered up front for later specs. New runtime code
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
- **Skills inject instructions only — the gem's `SkillTool` is deliberately NOT attached (Spec 3).**
  Verified against `ruby_llm-skills` 0.3.0: `require "ruby_llm/skills"`; `RubyLLM::Skills.load(dir)`
  returns a `Skill` exposing `#content` (SKILL.md body, lazy) — its `scripts`/`references`/`assets`
  are arrays of *file paths*, not `RubyLLM::Tool`s. A loaded skill ships no tools. `Nexo::Agent#chat`
  appends `skill.content` via `with_instructions(content, append: true)` (after base instructions, in
  declaration order). It does **not** call `chat.with_skills` / attach `RubyLLM::Skills::SkillTool`,
  whose `#execute` does ungated `File.read` of skill resources — attaching it would let the agent
  read files outside the sandbox/permission seam. The model reaches a skill's `references/`/`scripts/`
  through Nexo's own gated `ReadFile`/`Shell` tools instead. (Longer rationale: Recuerd0 ws 62.)
- **`Nexo::Skills.load!` keeps a bare `require` (Spec 3).** The lazy `require "ruby_llm/skills"`
  rescues **stdlib** `LoadError` → `Nexo::MissingDependencyError` (the gem's own
  `RubyLLM::Skills::LoadError` is a `StandardError`, not stdlib `LoadError`). `find` does its own
  `File.exist?` check and raises `Nexo::Error` naming the path *before* calling the gem loader. Tests
  simulate the gem being absent by stubbing `Nexo::Skills.require` to raise `LoadError`, so the call
  must stay a bare `require` resolving to the module's own (Kernel) method — don't rewrite it to
  `Kernel.require`/`require_relative`. `ruby_llm-skills` is a dev dep + soft runtime dep (never a
  gemspec `add_dependency`); `require "nexo"` with it absent must not raise.
- **Loop seam Zeitwerk placement + inflections (Spec 4).** The base class is `lib/nexo/loop.rb` →
  `Nexo::Loop`; the backends live under `lib/nexo/loops/` → `Nexo::Loops`. Do **not** put
  `class Loop` in `lib/nexo/loops.rb` (that path resolves to `Nexo::Loops` and breaks autoloading).
  `lib/nexo.rb` registers **two** inflections — `"ruby_llm" => "RubyLLM"` and
  `"agent_sdk" => "AgentSDK"` — so `loops/ruby_llm.rb` → `Loops::RubyLLM` and `loops/agent_sdk.rb` →
  `Loops::AgentSDK`. `Agent#prompt` now just delegates to the injected `@loop` (default
  `Loops::RubyLLM.new`); the old inline `chat.ask` body lives only in `Loops::RubyLLM`.
- **`Loops::AgentSDK` keeps a bare `require` + is dep-free (Spec 4).** `#run` does
  `require "ruby_llm/agent_sdk"` and rescues stdlib `LoadError` → `Nexo::MissingDependencyError`.
  `ruby_llm-agent_sdk` is **not** a dependency — not runtime, **not even dev** (per the spec), so the
  offline suite can't reach a real `.query`. Tests stub it two ways: define a recording
  `::RubyLLM::AgentSDK` module and stub `require` on the **loop instance** (`loop.stub(:require, …)`)
  to no-op for the happy path / raise `LoadError` for the missing-dep path. Keep it a bare `require`
  resolving to the instance's own (Kernel) method. `RubyLLM::AgentSDK.query`'s signature + the
  `:result` terminal message shape remain **VERIFY-on-install** — confirm against the gem's README the
  moment it's added, then record under "Verified APIs".
- **Turn-count observability is real but cap-less (Spec 4).** `RubyLLM::Chat#before_tool_call` /
  `#after_tool_result` **exist** on `ruby_llm` 1.16.0 (legacy aliases of `#on_tool_call`/
  `#on_tool_result`); `Loops::RubyLLM` wires them guarded by `respond_to?(:before_tool_call)`, so a
  version lacking them degrades to no observability, not a crash. The `turns` counter is incremented
  for visibility only — `ruby_llm` runs the whole loop inside `#ask` and exposes **no** public
  max-turns setting, so `Loops::RubyLLM` has no hard cap (use `Loops::AgentSDK` for that). Nexo→SDK
  permission map: `:read_only → :default`, `:auto → :bypass_permissions`, `:ask → :default` (ask
  stays gated in Nexo's own `on_ask`).
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
  assertion); `ruby_llm-test`'s `stub_response` is a **queue** (one response per request) — use
  `stub_responses(*n)` for fan-out or the extra prompts raise `NoResponseProvidedError`.
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
- **Loop event payload shapes → the type-aware `serializable` reducer (Spec 8, VERIFIED ruby_llm
  1.16.0).** Never `emit` a raw ruby_llm object (won't round-trip through the AR json column). The
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
- **Instruction idempotency across resumes is `acts_as_chat`'s, not ours (Spec 10, VERIFIED
  ruby_llm 1.16.0).** `Agent#chat(base: record)` re-applies `with_instructions(@instructions)` on
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
- **Session Rails test shells out, like WorkflowRun (Spec 10).** `test/session_test.rb` execs
  `test/support/session_model_check.rb` via `Bundler.with_unbundled_env` (boots AR + in-memory SQLite
  + the four `acts_as_chat` host models WITH the addressing columns + a stubbed model) and asserts OK
  markers. It threads the agent's model onto the persisted chat with `provider :openai` +
  `assume_model_exists true` (R7) so `#to_llm` bypasses the AR model-registry lookup. The plain-Ruby
  memory path is covered inline in `test/session_memory_test.rb` + `test/no_rails_test.rb`. `require
  "ruby_llm/active_record/{model,message,tool_call,chat}_methods"` must precede
  `require "ruby_llm/active_record/acts_as"` — `acts_as.rb` does not autoload those method modules.

- **`ActiveSupport::Notifications` becomes defined in the COMBINED offline suite (Spec 11).** A bare
  `require "nexo_ai"` (or webmock/ruby_llm-test/async/ruby_llm each alone) leaves `::ActiveSupport::
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

- **Durable approval bridges `:approve` → `suspend!` on Branch A (Spec 16, VERIFIED ruby_llm 1.16.0).**
  Group 0 confirmed a tool `execute` exception PROPAGATES out of `chat.ask`: `Chat#execute_tool`
  (`chat.rb:389`) → `tool.call` (`tool.rb:105`) → `execute(**args)` has NO rescue in the chain, and
  `RubyLLM.instrument` (`instrumentation.rb:12,20`) yields without rescuing; `Loops::RubyLLM#run` and
  `Agent#prompt` don't rescue either. So `Nexo::ApprovalRequired` (top-level, `< StandardError` like
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

## Verified APIs (Spec 5)

- **ruby_llm 1.16.0 HTTP adapter is fiber-friendly.** `RubyLLM::Connection` builds Faraday with
  `@config.faraday_adapter || :net_http` (default `:net_http`), which yields on socket I/O under the
  fiber scheduler. No native "async mode" to prefer; `Loops::RubyLLM` needs no change to run in a
  reactor.
- **Offload primitive = `Thread.new(&block).value`.** `Async::WorkerPool` is NOT present in the
  installed `async` 2.41.0 (`require "async/worker_pool"` → LoadError; const undefined). Shipped the
  always-works `Thread#value` fallback (it re-raises block exceptions in the caller).
- **SPIKE — parallel tool calls: a clean public seam EXISTS (still out of scope for v1).** ruby_llm
  1.16.0 already supports concurrent tool execution via a public API: `chat.with_tools(*tools,
  concurrency:)` / `RubyLLM.config.tool_concurrency` → `Chat#handle_tool_calls` dispatches to
  `handle_concurrent_tool_calls` → `ToolConcurrency.run`. No monkeypatch needed. Left unbuilt per the
  spec; a future spec can wire `concurrency:` through `Agent`/`Loops::RubyLLM` cleanly.

## Verified APIs (Spec 6 — ruby_llm-mcp 1.0.0)

Group-0 probes against the installed `ruby_llm-mcp` 1.0.0 (soft dev-only dep; unversioned in
the Gemfile, NOT a gemspec `add_dependency` — `require "nexo"` with it absent must not raise;
`Nexo::MCP.load!` bare-`require`s `ruby_llm/mcp` and rescues stdlib `LoadError` →
`MissingDependencyError`, mirroring `Skills.load!`):

- **Client constructor:** `RubyLLM::MCP.client(name:, transport_type:, config: {})`. Nexo's
  `MCP.build(name:, transport:, **config)` maps `name→name`, `transport→transport_type`, and
  collects **every other kwarg into `config:`** verbatim (stdio: `command:`/`args:`; sse:
  `url:`). Client **connects on construction** (`start: true` default) and is reusable across
  prompts until torn down.
- **Tools + tool shape:** `client.tools` → Array of `RubyLLM::MCP::Tool` (which **subclasses
  `RubyLLM::Tool`**). `#name`, `#description`, `#params_schema`; the tool body is `#execute(**params)`
  but the chat loop invokes `tool.call(args)` with a **positional Hash** (`RubyLLM::Tool#call`
  normalizes + dispatches to `#execute`).
- **Attach = duck-typed, no subclass required.** `RubyLLM::Chat#with_tool` does NOT type-check —
  it stores any object responding to `#name` and the loop calls `tool.call(args)`. So
  `MCP::GatedTool` is a **plain delegating wrapper** (explicit `#name`/`#call`, `method_missing`
  forwards `description`/`params_schema`/`to_h`), NOT a `RubyLLM::Tool` subclass. `#call`
  authorizes via `authorize_mcp!` then delegates; `rescue Denied → {error:}` (never raised into
  the loop), mirroring `tools/write_file.rb`.
- **Teardown = `#stop`, not `close`.** `RubyLLM::MCP::Client` exposes `start`/`stop`/`restart!`
  (no `close`). `Agent#close` calls `client.stop` (guarded, falls back to `close` for other
  client shapes) and clears the instance memo (`@mcp_clients`).
- **Gate is a second axis.** `authorize_mcp!(name, args)` is a sibling of `authorize!` — the
  sandbox `authorize!`/`@allow` path is byte-for-byte unchanged. `mcp_allow` (exact-match, no
  globs) defaults to `[]` ⇒ under `:read_only` every MCP tool is denied (fail closed). The
  `test_missing_gem` guard must check `Gem::Specification.find_all_by_name` (installability),
  NOT `defined?(RubyLLM::MCP)` — the constant is absent until first lazy `require` even when the
  gem is installed.

## Repo

`origin` → `git@github.com:maquina-app/nexo.git` (note: repo is `nexo`, gem is `nexo_ai`).
Conventional Commits (`chore:`, `feat:`, etc.). Default branch `main`.
