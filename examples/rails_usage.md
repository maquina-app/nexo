# Rails runtime — `run_later`, live progress, run helpers

Spec 11 turns Nexo's Rails engine into a real runtime: run a `Workflow`
asynchronously on your **existing** ActiveJob adapter, broadcast its events live
over `ActiveSupport::Notifications` (with an opt-in Turbo mirror), and query runs
and artifacts from your own controllers. Nexo ships **no queue, no scheduler, no
cable backend, and no UI** — only these primitives plus one overridable partial.

This walkthrough is host-side glue you write; nothing here is provided by Nexo
beyond the workflow API and the `nexo/event` partial.

## 1. Install the store (needed for cross-process `run_later`)

`run_later` enqueues a job that carries only the run id; the worker looks the run
up in the store. For a worker in **another process** to find it, use the
ActiveRecord store:

```sh
rails g nexo:install     # config/initializers/nexo.rb
rails g nexo:workflows   # the nexo_workflow_runs migration
rails db:migrate
```

In `config/initializers/nexo.rb`, opt into the pieces you want:

```ruby
Nexo.configure do |config|
  config.default_model = ENV["NEXO_MODEL"]
  config.job_queue = :nexo         # route workflow jobs to a dedicated queue (optional)
  config.broadcast_events = true   # opt-in Turbo mirror (requires turbo-rails)
end
```

## 2. A workflow

```ruby
# app/workflows/generate_report.rb
class GenerateReport < Nexo::Workflow
  def call(payload)
    emit(:fetching, account_id: payload[:account_id])
    data = Account.find(payload[:account_id]).report_data
    emit(:rendering, rows: data.size)
    artifact("report.csv", content: to_csv(data))   # a named deliverable on the run
    { rows: data.size }
  end
end
```

## 3. Kick it off from a controller and return immediately

```ruby
class ReportsController < ApplicationController
  def create
    @run = GenerateReport.run_later(account_id: params[:account_id])
    # returns at once — status "queued"; the worker runs it in the background
    redirect_to report_path(@run.id)
  end

  def show
    @run = Nexo::WorkflowRun.find(params[:id])
  end
end
```

Synchronous execution is the same call without `_later` (identical payload):

```ruby
run = GenerateReport.run(account_id: 42)   # blocks; returns a "done"/"failed" run
```

## 4. Live progress on the show page (Turbo)

With `config.broadcast_events = true` and turbo-rails present, the engine mirrors
each `nexo.workflow.event` to a per-run Turbo stream. Add the stream + a container
to your own view; appended events target `nexo_run_<id>_events`:

```erb
<%# app/views/reports/show.html.erb %>
<h1>Report run <%= @run.id %></h1>
<p>Status: <span id="run_status"><%= @run.status %></span></p>

<%= turbo_stream_from "nexo_run_#{@run.id}" %>
<div id="nexo_run_<%= @run.id %>_events">
  <%# events append here as they happen %>
</div>
```

Style them by overriding the engine's default partial in your app — a host-defined
`app/views/nexo/_event.html.erb` takes precedence:

```erb
<%# app/views/nexo/_event.html.erb (host override) %>
<div class="event event--<%= event["type"] %>">
  <strong><%= event["type"] %></strong>
  <code><%= event["data"].inspect %></code>
</div>
```

## 5. Not using Turbo? Subscribe to the notifications yourself

Both notifications fire regardless of Turbo — subscribe for logging, metrics, or a
different transport:

```ruby
ActiveSupport::Notifications.subscribe("nexo.workflow.event") do |*, payload|
  StatsD.increment("nexo.event", tags: ["type:#{payload[:event]["type"]}"])
end

ActiveSupport::Notifications.subscribe("nexo.workflow.status") do |*, payload|
  Rails.logger.info("[run #{payload[:run_id]}] -> #{payload[:status]}")
end
```

## 6. Build a runs list with the helpers

```ruby
Nexo::WorkflowRun.running          # scope
Nexo::WorkflowRun.queued           # scope
Nexo::WorkflowRun.finished         # scope: "done" or "failed"

run.running?  run.done?  run.failed?  run.queued?   # predicates

# Serve an artifact from your own controller (Nexo exposes content only):
send_data run.artifact_content("report.csv"),
          filename: "report.csv", type: "text/csv"
```

## Caveats (read before shipping)

- **Not resumable / no automatic retries.** A crashed or retried job re-runs
  `#call` from scratch — Nexo adds no `retry_on`. Configure retries in your host
  job if wanted, and run `rake nexo:reconcile` (or
  `Nexo::Workflow.reconcile_interrupted!`) once at boot to sweep runs orphaned in
  `"running"`.
- **`run_later` needs a shared store.** Use the AR store with a real adapter so a
  worker in another process finds the run. The in-memory store only works under the
  `:inline`/`:test` adapters (job runs in-process on enqueue).
- **Broadcast reachability.** Broadcasts fire from wherever the run executes — under
  `run_later`, the worker process. Your cable backend (AnyCable, Solid Cable, Redis)
  must be reachable from workers, not just web dynos. Nexo ships no cable server;
  without turbo-rails, `broadcast_events` is a no-op (the notifications still fire).
