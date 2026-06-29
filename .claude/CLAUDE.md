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

Local Ruby is 4.0.0 via mise, but the gem targets Ruby 3.2+ (`required_ruby_version >= 3.2.0`).
Keep new code compatible with 3.2.

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

## Repo

`origin` → `git@github.com:maquina-app/nexo.git` (note: repo is `nexo`, gem is `nexo_ai`).
Conventional Commits (`chore:`, `feat:`, etc.). Default branch `main`.
