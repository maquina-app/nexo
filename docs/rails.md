# Rails
Rails wiring: background execution with `run_later`, live progress broadcasting, and run-query helpers for a host UI.

The install generator (`rails g nexo:install`) is covered in [Getting started](getting-started.md);
the per-feature generators (`rails g nexo:workflows`, `nexo:artifacts`, `nexo:state`, `nexo:skill`)
live with their topics in [Workflows](workflows.md), [Durable workflows](durable-workflows.md), and
[Skills](skills.md).

## Background execution — `run_later`

`MyWorkflow.run_later(payload)` enqueues the run on your **existing ActiveJob
adapter** and hands back the run **immediately** (status `"queued"`), so a
controller can return while the work happens in the background. The job carries
**only the run id** — the payload lives on the run record, so no arguments (and
no secrets) travel through the queue. When the worker picks it up, it reconstitutes
the workflow and calls the same `execute` the sync path uses, so an async run
reaches the identical `done`/`failed` lifecycle, event log, and status
notifications:

```ruby
class GenerateReport < Nexo::Workflow
  def call(payload) = { url: build_report(payload[:account_id]) }
end

run = GenerateReport.run_later(account_id: 42)   # returns at once
run.status                                        # => "queued"
# ...the worker runs it in the background; later:
Nexo::RunStore.default.find(run.id).status        # => "done"
```

Route jobs to a dedicated queue per call or globally:

```ruby
GenerateReport.run_later(account_id: 42, queue: :nexo)  # per-call
Nexo.configure { |c| c.job_queue = :nexo }              # or a global default
```

Nexo ships **no queue and no scheduler** — ActiveJob uses whatever adapter your
app configured (Sidekiq, GoodJob, Solid Queue, …), and scheduling (cron / GoodJob
/ `whenever`) stays the host's. Without ActiveJob, `run_later` raises
`Nexo::MissingDependencyError` — use `run` for synchronous execution.

> **⚠️ Needs a shared store.** For a worker in **another process** to find the run,
> use the ActiveRecord store (`rails g nexo:workflows`) with a real adapter — the
> run must live in the database, not in a per-process memory store. The in-memory
> store only works under the `:inline`/`:test` adapters, where the job runs
> in-process on enqueue.
>
> **⚠️ No automatic crash recovery / no automatic retries.** A crashed or retried
> job re-runs `#call` **from scratch** — Nexo adds no `retry_on` (configure retries
> in your host job if you want them). Pair with `reconcile_interrupted!` (above) to
> sweep runs orphaned in `"running"`. For an *intentional* pause-and-continue (a
> human approval, an external callback), see **[Durable workflows](durable-workflows.md)** —
> `checkpoint` skips already-paid-for work when a run resumes.

## Live progress — notifications and opt-in Turbo

Every run **broadcasts as it happens** over `ActiveSupport::Notifications`,
decoupled from persistence (events still buffer/persist separately). Two
notifications fire (a no-op with no ActiveSupport, so the plain-Ruby core stays
Rails-free):

- `nexo.workflow.event` — one per `emit`, payload `{ run_id:, event: }` (the event
  is the string-keyed `{"type" =>, "data" =>, "at" =>}` hash). Fires **live**, even
  when event *persistence* is buffered.
- `nexo.workflow.status` — on each status transition, payload `{ run_id:, status: }`.

The payloads carry only what `emit`/the run already hold — **no payload or
credential dumps**. Subscribe for logging, metrics, or your own UI:

```ruby
ActiveSupport::Notifications.subscribe("nexo.workflow.event") do |*, payload|
  Rails.logger.info("[run #{payload[:run_id]}] #{payload[:event]["type"]}")
end
```

**Opt-in Turbo mirror.** Set `config.broadcast_events = true` (and have turbo-rails
present) and the engine subscribes `Nexo::TurboBroadcaster`, which appends each
event to a per-run Turbo stream, rendering the overridable partial
`app/views/nexo/_event.html.erb`. To show live progress, add to your own page (Nexo
ships **no** controllers, routes, or dashboard — the host owns all HTTP + UI):

```erb
<%= turbo_stream_from "nexo_run_#{@run.id}" %>
<div id="nexo_run_<%= @run.id %>_events">
  <%# appended events land here %>
</div>
```

Override the appearance by defining your own `app/views/nexo/_event.html.erb` in
the host app — it takes precedence over the engine's default (which renders
`<div class="nexo-event">type: {data.inspect}</div>`).

```ruby
Nexo.configure { |c| c.broadcast_events = true }   # opt in; requires turbo-rails
```

> **⚠️ Broadcast reachability.** Broadcasts fire from **wherever the run executes**
> — under `run_later`, that's the worker process. The cable backend (AnyCable,
> Solid Cable, Redis) must therefore be reachable from your workers, not just your
> web dynos. Nexo ships **no cable backend** — broadcasting composes whatever the
> host configured. Without turbo-rails, `broadcast_events` is a harmless no-op:
> the notifications still fire, so you can subscribe to them yourself.

## Run helpers for a host UI

`Nexo::WorkflowRun` exposes query helpers so a host can build its own runs UI
without Nexo dictating controllers or views:

```ruby
Nexo::WorkflowRun::STATUSES  # => %w[pending queued running done failed interrupted suspended]

Nexo::WorkflowRun.queued     # scope: status "queued"
Nexo::WorkflowRun.running    # scope: status "running"
Nexo::WorkflowRun.finished   # scope: status "done" or "failed"
Nexo::WorkflowRun.suspended  # scope: status "suspended" (paused, awaiting resume)

run.queued?  run.running?  run.done?  run.failed?  run.suspended?   # predicates

# Artifact access — content only; serving files stays your
# controller's job (Nexo ships no artifact routes/controllers):
run.artifact("digest.md")          # => {"name" =>, "content" =>, "at" =>} or nil
run.artifact_content("digest.md")  # => "…the body…" or nil
```

See [`examples/rails_usage.md`](../examples/rails_usage.md) for a controller +
Turbo-page walkthrough.

← Back to the [README](../README.md)
