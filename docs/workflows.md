# Workflows
A workflow is a finite job with a stable runId, status, payload, result, and an inspectable event log.

An **agent** accumulates context — it keeps a conversation going. A **workflow**
fires and finishes: a finite job with a stable runId, a `status`, a `payload`, a
`result`, and an ordered, inspectable event log. Subclass `Nexo::Workflow`,
implement `#call(payload)`, and run it:

```ruby
require "nexo"

class SummarizeDocument < Nexo::Workflow
  def call(payload)
    emit(:started, doc_id: payload[:doc_id])
    summary = payload[:text].to_s.slice(0, 280)   # pure Ruby — no Agent needed
    emit(:summarized, length: summary.length)
    { summary: summary }
  end
end

run = SummarizeDocument.run(doc_id: 123, text: "Long text…")
run.id      # => "0191d6b2-…"  (UUID v7 string, time-ordered)
run.status  # => "done"
run.result  # => { "summary" => "Long text…" }
```

`#call` receives a **symbol-keyed** payload; the stored `payload` and `result`
read back **string-keyed** (they survive a JSON round-trip identically whether
the run lives in memory or in the database).

## Failure model — workflows re-raise

A workflow that raises is recorded as `failed` with the error message **and the
exception still propagates** to your caller:

```ruby
run = BoomWorkflow.run     # raises — but the run is persisted as failed first
# => RuntimeError: kaboom
```

This is deliberately the opposite of a Nexo *tool* failure, which returns
`{ error: … }` and never raises into the agent loop. A tool error is recoverable
context for the model; a workflow failure is a job that did not complete.

By default a failed run is **not** retried — the exception is yours to handle. For
long-running or human-in-the-loop jobs that must pause and continue later (possibly
in another process), Nexo adds durable **checkpoints**, `suspend!`, and `resume` on
top of this same lifecycle — see [Durable workflows](durable-workflows.md). Runs
orphaned in `"running"` by a crashed worker are swept to `"interrupted"` by
[`reconcile_interrupted!`](#reconciling-interrupted-runs).

## The event log — `emit` and `nexo logs`

`emit(:type, data)` appends an ordered event (`type`, `data`, `at`) and persists
it incrementally. Inspect a run's log in plain Ruby:

```ruby
Nexo::Workflow.logs(run.id) { |ev| puts "#{ev["at"]} #{ev["type"]}" }
```

or, in a Rails app, from the terminal:

```sh
$ bundle exec rake "nexo:logs[0191d6b2-7c4a-7e1f-9a3b-2f5c8d1e6b00]"
[2026-06-29T14:02:01Z] started      {"doc_id"=>123}
[2026-06-29T14:02:01Z] summarized   {"length"=>280}
```

## With or without Rails

With no Rails loaded, runs record to an in-memory store — workflows run, emit,
and `Nexo::Workflow.logs` works, all offline with no database. In a Rails app,
install the migration and runs persist to a `nexo_workflow_runs` table:

```sh
rails g nexo:workflows
rails db:migrate
```

The same `Workflow` code drives either backend; `Nexo::RunStore.default` selects
ActiveRecord when it is available and the in-memory store otherwise. The schema
uses portable `json` columns (SQLite and PostgreSQL alike) and a UUID string
primary key.

## Input staging and artifacts

A run owns a **sandbox** — declared with the `sandbox` class macro (default
`:virtual`, the safe in-memory sandbox; `:local` for the host filesystem rooted
at the `cwd` macro, default `Dir.pwd`). It is resolved **lazily**: a data-only
workflow that never touches files builds nothing, so the plain `emit`/`result`
path stays free.

A `Workflow` accepts the **same sandbox forms as an `Agent`** — they share one
resolver (`Nexo::Sandboxes.resolve`), so the two can't drift. Alongside
`:virtual`/`:local` and a pre-built `Nexo::Sandbox` instance, a workflow can
declare a hardened container just like an agent:

```ruby
class BuildInContainer < Nexo::Workflow
  sandbox :docker, image: "node:22-slim"   # or :apple, or { type: :docker, ... }
  def call(_payload) = { ok: true }
end
```

The container runs its tools — and the shared sandbox any agent driven via
`run_agent` inherits — inside the same hardened image (`network: none`, dropped
capabilities, read-only rootfs by default). As with an agent, `image:` is
required, and the host `cwd` applies only to `:local`: a container keeps its own
`/workspace` (see [Container sandbox](sandboxes.md#container-sandbox--docker--apple-container)).

`stage(files)` writes provided inputs into that sandbox *before* your `#call`
work begins. It takes either a `{ "path" => "content" }` hash or an array of
`{ path:, content: }` hashes, emits a `:staged` event with the count, and returns
the count staged.

`artifact(name, content:)` records a **named deliverable** on the run — a digest,
a report, an improved file, a generated script. The body is written to the
sandbox at `artifacts/<name>` (so later steps can read it) and recorded on the
run. `run.artifacts` reads it back as an **ordered array** of string-keyed hashes
(`{"name" =>, "content" =>, "at" =>}`) in both stores:

```ruby
class BuildDigest < Nexo::Workflow
  def call(payload)
    stage(payload[:files])                       # baseline + extras into the sandbox
    artifact("digest.md", content: summarize(sandbox.read("/workspace/baseline.md")))
    { ok: true }
  end
end

run = BuildDigest.run(files: [{ path: "baseline.md", content: "…" }])
run.artifacts.first["name"]     # => "digest.md"
run.artifacts.first["content"]  # => "…the digest body…"
```

You can also render an artifact from a **template you control** with `from:` —
no templating engine, just stdlib `ERB`:

```ruby
# from: is a real disk file when it exists, else a staged sandbox path.
artifact("digest.md", from: "app/templates/digest.md.erb",
         locals: { title: "Weekly", baseline: sandbox.read("/workspace/baseline.md") })
```

> **⚠️ Templates are code, not data.** `ERB` executes arbitrary Ruby. A template
> passed to `artifact(from:)` **must** be a trusted, developer-authored file —
> **never** model output or user-uploaded content. Rendering a model-generated
> or uploaded template is remote code execution. If a body is untrusted, pass it
> as `content:` (inert data), not as a `from:` template.

See [`examples/artifact_from_template.rb`](../examples/artifact_from_template.rb) for
the full offline flow (`ruby -Ilib examples/artifact_from_template.rb`).
### Agent output — `produces`

`from:` renders ERB and is **only** for templates you wrote. An agent's output is model
output, so it is copied **verbatim** instead. An agent declares what it produces, and may
produce as many artifacts as it likes:

```ruby
class Publisher < Nexo::Agent
  skills :dashboard_designer
  produces "dashboard.html", "digest.json", "out/*.csv"
end
```

`run_agent` copies those out of the sandbox and records them on the run the moment the
agent finishes — **including when it suspended for approval or raised**, which are exactly
the paths where results would otherwise be lost. Under the hood that is
`artifact(name, path:)`, the verbatim third mode, which you can also call directly.

Why this matters: a workflow builds **one** sandbox that every `run_agent` borrows, so a
hand-off between stages is just "agent B reads a path agent A wrote". On `:local` that is a
real directory and survives anything. On `:docker`/`:apple` it does not — `Container#close`
is `rm -f`, and a run's sandbox is released on **every** terminal path, `suspended`
included. So pausing for a human approval destroyed everything produced before the pause,
while the identical code on `:local` kept it. Declared artifacts survive the teardown.

Declared, never inferred: sweeping the sandbox would also collect staged skill scripts,
templates and scratch files, and naming outputs is the only honest way for an agent to say
it produced nothing. A declared artifact that was never written is skipped, not fatal.

Bytes that are not valid UTF-8 are Base64-wrapped so they survive a JSON column. Read a
body back with `Nexo::Workflow.artifact_body(art)` rather than `art["content"]`, which is
Base64 text for binary.

### Handing output to the next stage — `restore_artifacts`

```ruby
run_agent("extract")          # Extractor produces gmail.json
restore_artifacts             # put recorded artifacts back in the sandbox
run_agent("synthesize")       # Synthesizer reads gmail.json
```

`Skills.materialize` gets a skill's files *into* a sandbox; this is the other direction and
then back in again, so a pipeline behaves the same whether the tier is persistent or
ephemeral — including across a suspend and resume, where the sandbox that held the files no
longer exists. Pass `only:` to restore a subset.


The `artifacts` column ships with fresh installs. Apps installed before this
release add it with:

```sh
rails g nexo:artifacts
rails db:migrate
```

## Tasks & Actions

A workflow can **declare and drive an agent** so the two primitives Nexo owns —
a `Workflow` (the run lifecycle) and an `Agent` (the skilled, sandbox-backed
model loop) — compose into one recipe: *stage inputs → run the agent → capture
artifacts*. The `agent` class macro names the `Agent` subclass this workflow
drives; `run_agent(prompt, max_turns: 25)` runs it **bound to the run's own
sandbox**, forwards every tool call/result and the final response into the run
log as `agent_*` events, and closes the agent afterward (tearing down any MCP
servers). It returns the agent's response — read `response.content`.

```ruby
class ReviewBaseline < Nexo::Workflow
  agent CodeReviewer            # the Agent subclass this workflow drives

  def call(payload)
    stage(payload[:files])                          # inputs into the run's sandbox
    resp = run_agent("Review the staged baseline and report OK or the issues.")
    artifact("review.md", content: resp.content)    # capture the agent's output
    { content: resp.content }
  end
end
```

Because it composes the existing agent loop's observability seam through the
same `emit` path, a driven run reads as one coherent story —
`Nexo::Workflow.logs(run.id)` (and `nexo:logs`) interleaves the workflow's own
events with the agent's:

```
[…] staged            {"count"=>1}
[…] agent_tool_call   {"name"=>"read_file", "args"=>{"path"=>"/workspace/baseline.md"}}
[…] agent_tool_result {"ok"=>true, "content"=>"…"}
[…] agent_done        {"content"=>"REVIEW OK"}
```

The **same** workflow runs two ways with no code difference — Nexo stays
*schedulable*, never a scheduler.

**As a scheduled Task** — invoke it from a background job (the scheduling itself
lives in the host: cron / GoodJob / `whenever` / any job system):

```ruby
class ReviewBaselineJob < ApplicationJob
  def perform(files:)
    ReviewBaseline.run(files: files)   # same run entry point
  end
end

# scheduled elsewhere in the host — Nexo does not schedule:
ReviewBaselineJob.perform_later(files: nightly_baseline)
```

**As an interactive Action** — invoke the *same* `run` from a controller after
staging the uploaded files:

```ruby
class ReviewsController < ApplicationController
  def create
    files = params[:files].map { |f| { path: f.original_filename, content: f.read } }
    run = ReviewBaseline.run(files: files)   # identical call — no code difference
    redirect_to review_path(run.id)
  end
end
```

> **⚠️ Shared-sandbox precedence.** Under `run_agent` the agent uses the
> **workflow's** sandbox; the agent's own `sandbox` class macro is **ignored**
> (it only applies when the agent runs standalone via `.new.prompt`). The agent
> keeps its **own** `permissions`, `skills`, `mcp`, and `mcp_allow`: the workflow
> provides the *where* (sandbox), the agent owns the *what* (permissions) and the
> *how* (skills/instructions). Driving an agent never widens its authority — its
> safe default (`:read_only`) is untouched.

See [`examples/inbox_digest_task.rb`](../examples/inbox_digest_task.rb) for a live
example that wraps the MCP-backed `InboxTriage` agent in a workflow and captures
the digest as an artifact.

## Reconciling interrupted runs

A crashed worker leaves runs stuck in `"running"`. `Nexo::Workflow.reconcile_interrupted!`
is a **one-shot boot/deploy sweep** that rewrites only `"running"` → `"interrupted"`
(never touching `"done"` or `"failed"`) and returns the count. It is **never
auto-invoked** — call it from a boot hook or the shipped rake task:

```sh
bundle exec rake nexo:reconcile
```

> This is **not** a liveness check. It cannot tell a genuinely-running run in
> another process from an orphaned one — so run it once at boot, *before* any
> worker starts new runs, not while workers are live.

← Back to the [README](../README.md)
