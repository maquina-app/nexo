## [Unreleased]

## [0.5.0] - 2026-06-29

### Added

- **Pluggable loop backends.** `Nexo::Loop` is the new engine seam:
  `#run(agent:, prompt:, max_turns:, &on_event)`. Swap the loop by constructor
  injection (`loop:`) without changing the agent class.
- `Nexo::Loops::RubyLLM` (DEFAULT, provider-neutral) — the Spec 1 `Agent#prompt`
  loop logic extracted verbatim. It runs on any `ruby_llm` model and contains no
  vendor code. Wires turn-count *observability* through `RubyLLM::Chat`'s
  `before_tool_call`/`after_tool_result` callbacks (guarded by `respond_to?`),
  forwarding `:tool_call`/`:tool_result`/`:done` to an optional `on_event` block.
- `Nexo::Loops::AgentSDK` (opt-in, Anthropic-oriented) — wraps
  `RubyLLM::AgentSDK.query` for native `max_turns`, permission modes, and the
  SDK's built-in tools. `ruby_llm-agent_sdk` is a SOFT/optional dependency,
  required lazily; a clear `Nexo::MissingDependencyError` is raised when it's
  absent. Not a dependency of this release (its `.query` signature is
  verified-on-install).
- `Nexo::Sandboxes::Remote` — run an agent's tools inside a remote container by
  injecting any client satisfying the four-method contract (`read`/`write`/
  `exec`/`close`). Contains zero vendor code; switching providers is swapping the
  injected object. Vendor SDKs are adapted with a tiny documented shim.
- `Agent` gains a `loop:` option (default `Loops::RubyLLM.new`); `#prompt`
  delegates to it. New readers `#permission_mode` (Nexo→AgentSDK mode mapping:
  `:read_only`→`:default`, `:auto`→`:bypass_permissions`, `:ask`→`:default`) and
  `#allowed_tools` support the AgentSDK backend. `Permissions#mode` is now
  readable.

### Documented

- README: the loop/sandbox matrix, the two-configurations / same-agent example,
  the Remote shim pattern, the Nexo→AgentSDK permission mapping, and the turn-cap
  caveat (`Loops::RubyLLM` has no proven hard turn cap — observability only).

## [0.4.0] - 2026-06-29

### Added

- **Skills.** Drop a `SKILL.md` package into `app/skills/<name>/` and attach it
  to an agent with a single `skills :name` class macro — Nexo composes the
  existing `ruby_llm-skills` gem to load the skill's instructions, with zero
  loader setup. Skills guide *reasoning*; the sandbox-backed tools from Spec 1
  still perform *execution*.
- `Nexo::Skills.load!` lazily requires `ruby_llm-skills` (a SOFT/optional runtime
  dependency) and raises `Nexo::MissingDependencyError` with install guidance when
  it is absent; `require "nexo"` without the gem still loads cleanly.
- `Nexo::Skills.find(name)` resolves a skill from `Nexo.config.skills_path`
  (default `app/skills` under Rails), raising `Nexo::Error` that names the missing
  `SKILL.md` path when not found.
- `Nexo::Agent.skills(*names)` class macro; `#chat` layers each declared skill's
  instructions on top of the agent's own, in declaration order, after the
  sandbox-backed tools.
- A `nexo:skill NAME` generator scaffolding `app/skills/NAME/SKILL.md` (valid
  Agent Skills frontmatter) plus a kept `references/` directory.

### Safety

- Skill packages contribute **instructions only**: a loaded skill ships no
  independent tools, and Nexo deliberately does not attach `ruby_llm-skills`'
  progressive-disclosure tool (which reads files outside the sandbox). A skill's
  `references/`/`scripts/` files are reached through Nexo's own permission-gated,
  sandbox-backed tools, so attaching a skill never widens what an agent can do.

## [0.3.0] - 2026-06-29

### Added

- **WorkflowRun lifecycle primitive.** Subclass `Nexo::Workflow`, implement
  `#call(payload)`, and run it with `MyWorkflow.run(payload)` to get back a
  persisted run record carrying a UUID v7 runId, `status`, `payload`, `result`,
  `error`, and an ordered, inspectable event log.
- `#emit(type, data)` appends ordered events (persisted incrementally) and
  `Nexo::Workflow.logs(run_id)` / the `nexo:logs[run_id]` rake task inspect them.
- A storage seam `Nexo::RunStore` with two interchangeable backends: an
  in-memory store (plain Ruby, offline) and an ActiveRecord store (Rails),
  selected automatically by `Nexo::RunStore.default`.
- `Nexo::WorkflowRun` ActiveRecord model and a `nexo:workflows` generator that
  installs a portable (`json` columns, UUID string primary key) migration.
- `Nexo.generate_run_id` (UUID v7 on Ruby 3.3+, UUID v4 fallback on 3.2).
- A guarded `Nexo::Engine` wiring the generator, rake task, and model into a
  host Rails app; the core still runs in plain Ruby with no Rails loaded.

## [0.1.0] - 2026-06-21

- Initial release
