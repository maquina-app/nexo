## [Unreleased]

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
