## [Unreleased]

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
