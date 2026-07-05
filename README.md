# Nexo

> Agent = Model + Harness. Nexo is the connective tissue linking RubyLLM to tools,
> sandboxes, skills, and runs.

A model alone forgets everything the moment a response ends. The harness is everything
else. Nexo gives the RubyLLM ecosystem one cohesive front door with safe defaults —
build a working agent in five lines without wiring anything.

## Compose, don't reimplement

Nexo does not rebuild skill loading, the tool-call loop, MCP, or structured output — those
already live in the RubyLLM ecosystem (`ruby_llm` core, `ruby_llm-skills`, `ruby_llm-mcp`,
`ruby_llm-schema`). Nexo **composes** them behind one front door and adds only the two pieces
the ecosystem is missing:

- **Sandbox + Permissions seam** — pluggable execution environment (virtual / local /
  remote) with explicit authorization gating. Default: `:virtual` + `:read_only`.
- **WorkflowRun lifecycle** — a finite-job primitive (runId, status, payload, result,
  inspectable event log) that nothing else in the ecosystem provides cleanly.

## Installation

Add to your Gemfile:

```ruby
gem "nexo_ai"
```

Or install directly:

```sh
gem install nexo_ai
```

In a Rails app, run the install generator to create the conventional layout and an initializer:

```sh
rails g nexo:install
```

```
      create  app/agents/.keep
      create  app/workflows/.keep
      create  app/skills/.keep
      create  config/initializers/nexo.rb
```

## Configuration

Configure the harness in one place with `Nexo.configure`. Defaults are safe and
provider-neutral — there is intentionally no hardcoded model:

```ruby
Nexo.configure do |config|
  config.default_model       = ENV["NEXO_MODEL"] # provider-neutral: no default
  config.default_sandbox     = :virtual          # :virtual | :local
  config.default_permissions = :read_only        # :read_only | :auto | :ask
  config.skills_path         = "app/skills"
  config.concurrency         = :threaded         # :threaded | :async (opt-in fiber offload)
  config.max_in_flight       = 8                 # Nexo.concurrent fan-out bound
  config.buffer_workflow_events = false          # buffer + flush-once workflow events
end

Nexo.config.default_sandbox      # => :virtual
Nexo.config.default_permissions  # => :read_only
Nexo.config.default_model        # => nil unless set
```

`require "nexo"` (and `require "nexo_ai"`) works in plain Ruby with no Rails loaded.

## Build an agent in five lines

Subclass `Nexo::Agent`, declare the pieces with class macros, and call `#prompt`. No
sandbox, permission, or tool object is wired by hand, and nothing is vendor-specific —
the agent runs on any `ruby_llm`-supported model (set `NEXO_MODEL`, e.g. a local
`gemma3:12b` via Ollama, or a hosted model):

```ruby
require "nexo"

class CodeReviewer < Nexo::Agent
  model       ENV.fetch("NEXO_MODEL")   # any ruby_llm model — never a hardcoded vendor default
  sandbox     :local
  permissions :read_only

  instructions "You are a careful code reviewer. Read files and report issues. Do not write files."
end

CodeReviewer.new(cwd: "/path/to/repo").prompt("Review the auth module")
```

Defaults are safe: an agent with no `sandbox`/`permissions` declared gets the in-memory
`:virtual` sandbox and `:read_only` permissions, so an untrusted model has zero host
access until you explicitly opt in.

### Human-gated writes (`:ask`)

`:ask` mode defers every write/shell action to your callback. Build a `Permissions` with
an `on_ask` hook and pass it in:

```ruby
gate = Nexo::Permissions.new(mode: :ask, on_ask: ->(cap, detail) {
  $stdout.print("Allow #{cap} #{detail}? [y/N] "); $stdin.gets.strip == "y"
})

class Editor < Nexo::Agent
  model   ENV.fetch("NEXO_MODEL")
  sandbox :local
end

Editor.new(cwd: ".", permissions: gate).prompt("Fix the typo in README.md")
```

(The bare `:ask` symbol resolves to `Permissions.new(mode: :ask)` with **no** callback, so
writes/shell are denied — pass a pre-built `Permissions` with `on_ask` for a real gate.)

## Sandboxes & permissions

Two seams compose the execution environment. The **sandbox** is *where* tools act; the
**permission mode** is *what* they may do. A denied capability returns `{ error: ... }`
and the agent loop continues — it does not raise. A path that escapes the workspace raises
`SecurityError`; an agent built with no resolvable model raises `Nexo::ConfigurationError`.

|                          | `:read` | `:glob` | `:write`            | `:shell`                          | `:fetch`            |
| ------------------------ | ------- | ------- | ------------------- | --------------------------------- | ------------------- |
| `:read_only` (default)   | ✅      | ✅      | ❌ `{error}`        | ❌ `{error}`                      | ❌ `{error}`        |
| `:auto`                  | ✅      | ✅      | ✅                  | ✅                                | ✅                  |
| `:ask`                   | per `on_ask` | per `on_ask` | per `on_ask`   | per `on_ask`                      | per `on_ask`        |
| `Virtual` sandbox        | ✅      | ✅      | ✅ (in-memory)      | ❌ `NotImplementedError`→`{error}` | ✅ (network egress)  |
| `Local` sandbox          | ✅ (guarded) | ✅ | ✅ (guarded)        | ✅ (narrowed ENV)                 | ✅ (network egress)  |

- **`Virtual`** (default) — in-memory, zero host access. `#shell` raises
  `NotImplementedError` on purpose: in-memory means no command execution. That is the
  safety property, not a gap.
- **`Local`** — host filesystem + shell, for trusted dev/CI. Two guards: every path is
  expanded against `cwd` and must stay inside it (else `SecurityError`), and the shell sees
  only `PATH`, `HOME`, `LANG` (plus explicit `env:` additions) — never the full process
  environment.
- **`Remote`** — run the tools inside a remote container (E2B / Daytona / Modal / Docker /
  your own) by injecting a client. Escalating to `:remote` is always an explicit choice in
  your code — the default stays `:virtual`.

### Remote sandbox — bring your own container

`Sandboxes::Remote` contains **zero vendor code**. It wraps any object that satisfies a
four-method contract — `read`, `write`, `exec`, `close` — and delegates the `Sandbox`
interface to it. Switching providers is swapping the injected object, nothing else:

```ruby
sandbox = Nexo::Sandboxes::Remote.new(client: my_container_client)
# read(path)  -> client.read(path)
# write(path, content) -> client.write(path, content)
# shell(cmd, timeout:) -> client.exec(cmd, timeout:)
# glob(pattern)        -> client.exec("ls #{pattern}")[:stdout].split("\n")
# close                -> client.close
```

Vendor SDKs rarely expose exactly `read/write/exec/close`, so adapt them with a tiny shim
object. Keep the vendor gem a **soft** dependency behind a lazy `require` that raises
`Nexo::MissingDependencyError` when it's absent:

```ruby
# A ~10-line adapter wrapping a hypothetical vendor client to the four-method contract.
class E2BAdapter
  def initialize(api_key:)
    require "e2b"            # soft dep — lazy, only when you actually use it
    @sbx = E2B::Sandbox.create(api_key: api_key)
  rescue LoadError
    raise Nexo::MissingDependencyError, "E2BAdapter needs `gem \"e2b\"` in your Gemfile."
  end

  def read(path)            = @sbx.files.read(path)
  def write(path, content)  = @sbx.files.write(path, content)
  def exec(cmd, timeout: 30) = (r = @sbx.commands.run(cmd, timeout: timeout)
                                {stdout: r.stdout, stderr: r.stderr, status: r.exit_code})
  def close                 = @sbx.kill
end

agent = Nexo::Agent.new(model: ENV.fetch("NEXO_MODEL"),
                        sandbox: Nexo::Sandboxes::Remote.new(client: E2BAdapter.new(api_key: ENV["E2B_API_KEY"])))
```

Nexo ships **only** `Remote` plus this documented pattern — purpose-built
`Sandboxes::E2B` / `Sandboxes::Daytona` classes are a possible future addition, deliberately
left out of v1 because their vendor client APIs aren't pinned yet.

## Loop backends — swap the engine, not the agent

The **loop** is the engine that drives one prompt to completion. Swapping it is constructor
injection (`loop:`) — the agent class never changes. Two backends ship:

|                    | `Loops::RubyLLM` (default)         | `Loops::AgentSDK` (opt-in)            |
| ------------------ | ---------------------------------- | ------------------------------------- |
| Provider neutral   | ✅ any `ruby_llm` model            | ❌ Anthropic-oriented                 |
| Tool source        | your sandbox-backed tools          | the SDK's own built-in/host tools     |
| Turn cap           | observability only (see caveat)    | native `max_turns` hard cap           |
| Execution location | your sandbox (virtual/local/remote)| the host process                      |

The whole point: **same agent code, swapped backends**. Both examples are model-agnostic
(`ENV.fetch("NEXO_MODEL")` — never a hardcoded `"claude-…"`):

```ruby
# Claude fast path — AgentSDK's own loop + host tools + native max_turns
claude = Nexo::Agent.new(
  model: ENV.fetch("NEXO_MODEL"),
  sandbox: Nexo::Sandboxes::Local.new(cwd: "/srv/checkout"),
  permissions: Nexo::Permissions.new(mode: :auto),
  loop: Nexo::Loops::AgentSDK.new
)

# Any-provider path — your sandbox, your tools, human-in-the-loop
gpt = Nexo::Agent.new(
  model: ENV.fetch("NEXO_MODEL"),                # gpt-5.5, gemini, gemma3:12b via Ollama…
  sandbox: Nexo::Sandboxes::Remote.new(client: my_container_client),
  permissions: Nexo::Permissions.new(mode: :ask, on_ask: ->(cap, detail) {
    SlackApproval.request!(capability: cap, detail: detail)
  }),
  loop: Nexo::Loops::RubyLLM.new
)
```

`Loops::AgentSDK` wraps `RubyLLM::AgentSDK.query` and requires the **optional**
`ruby_llm-agent_sdk` gem (lazy `require`; a clear `Nexo::MissingDependencyError` if it's
absent). It maps Nexo's permission modes onto the SDK's own vocabulary:

| Nexo mode    | AgentSDK `permission_mode` |
| ------------ | -------------------------- |
| `:read_only` | `:default`                 |
| `:auto`      | `:bypass_permissions`      |
| `:ask`       | `:default` (human gating stays in Nexo's own `on_ask` path, not delegated to the SDK) |

### The turn-cap caveat (read before running untrusted/expensive workloads)

`ruby_llm` runs the whole tool loop inside `ask`, so `Loops::RubyLLM` has **no clean public
hard "stop after N turns" halt** — `before_tool_call` gives turn-count *observability*, not a
hard stop. (Confirmed: `ruby_llm` 1.16.0's `Chat` exposes no public max-turns/max-iterations
setting.) Your three real options:

(a) use `Loops::AgentSDK` (native `max_turns`) for untrusted/expensive workloads;
(b) have a tool return `{ error: "turn limit reached, stop and summarize" }` once a turn
    counter trips;
(c) check whether the installed `ruby_llm` exposes a max-iterations config (in 1.16.0 it
    does not).

Do **not** ship `Loops::RubyLLM` for untrusted workloads claiming a hard cap that isn't
proven.

### Verified vs assumed

Built against **`ruby_llm` 1.16** and **`ruby_llm-test` 0.2**. The tool body method is
`#execute`, tools attach with `chat.with_tools(*instances)`, and instructions set with
`chat.with_instructions`. `Open3.capture3` has no `timeout:` keyword on the target Ruby, so
`Local#shell` bounds the command with `Timeout.timeout`. These may differ on other
`ruby_llm` versions.

`Loops::RubyLLM`'s turn-count observability uses `RubyLLM::Chat#before_tool_call` /
`#after_tool_result`, confirmed present on `ruby_llm` 1.16.0 and guarded with `respond_to?`
so a version lacking them degrades to no observability rather than crashing.
`Loops::AgentSDK` targets `RubyLLM::AgentSDK.query`; `ruby_llm-agent_sdk` is **not** a
dependency of this release, so that signature is **assumed** (per the gem's README) and
verified-on-install — confirm it the moment you add the gem.

### Live smoke (optional)

The core suite is fully offline and deterministic (models stubbed with `ruby_llm-test`).
A real end-to-end check is opt-in and env-gated — small local models like Gemma have weak
tool-calling, so it may be flaky and is never a gating test:

```sh
ollama serve &
NEXO_LIVE=1 NEXO_MODEL=gemma3:12b bundle exec rake test TEST=test/live_smoke_test.rb
```

If Gemma's tool-calling proves too weak, point `NEXO_MODEL` at a stronger model — the gem
stays provider-neutral; only the smoke target changes.

## Workflows

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

### Failure model — workflows re-raise

A workflow that raises is recorded as `failed` with the error message **and the
exception still propagates** to your caller:

```ruby
run = BoomWorkflow.run     # raises — but the run is persisted as failed first
# => RuntimeError: kaboom
```

This is deliberately the opposite of a Nexo *tool* failure, which returns
`{ error: … }` and never raises into the agent loop. A tool error is recoverable
context for the model; a workflow failure is a job that did not complete.

Workflows are **not resumable**: an interrupted run is abandoned and you start a
new one. There is no checkpoint state and no `resume`.

### The event log — `emit` and `nexo logs`

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

### With or without Rails

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

### Input staging and artifacts

A run owns a **sandbox** — declared with the `sandbox` class macro (default
`:virtual`, the safe in-memory sandbox; `:local` for the host filesystem rooted
at the `cwd` macro, default `Dir.pwd`). It is resolved **lazily**: a data-only
workflow that never touches files builds nothing, so the plain `emit`/`result`
path stays free.

`stage(files)` writes provided inputs into that sandbox *before* your `#call`
work begins. It takes either a `{ "path" => "content" }` hash or an array of
`{ path:, content: }` hashes, emits a `:staged` event with the count, and returns
the count staged.

`artifact(name, content:)` records a **named deliverable** on the run — a digest,
a report, an improved file, a generated script. The body is written to the
sandbox at `/artifacts/<name>` (so later steps can read it) and recorded on the
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

See [`examples/artifact_from_template.rb`](examples/artifact_from_template.rb) for
the full offline flow (`ruby -Ilib examples/artifact_from_template.rb`).

The `artifacts` column ships with fresh installs. Apps installed before this
release add it with:

```sh
rails g nexo:artifacts
rails db:migrate
```

### Tasks & Actions

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

See [`examples/inbox_digest_task.rb`](examples/inbox_digest_task.rb) for a live
example that wraps the MCP-backed `InboxTriage` agent in a workflow and captures
the digest as an artifact.

### Reconciling interrupted runs

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

### Background execution — `run_later`

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
> **⚠️ Not resumable / no automatic retries.** A crashed or retried job re-runs
> `#call` **from scratch** — workflows aren't resumable and Nexo adds no `retry_on`
> (configure retries in your host job if you want them). Pair with
> `reconcile_interrupted!` (above) to sweep runs orphaned in `"running"`.

### Live progress — notifications and opt-in Turbo

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

### Run helpers for a host UI

`Nexo::WorkflowRun` exposes query helpers so a host can build its own runs UI
without Nexo dictating controllers or views:

```ruby
Nexo::WorkflowRun::STATUSES  # => %w[pending queued running done failed interrupted]

Nexo::WorkflowRun.queued     # scope: status "queued"
Nexo::WorkflowRun.running    # scope: status "running"
Nexo::WorkflowRun.finished   # scope: status "done" or "failed"

run.queued?  run.running?  run.done?  run.failed?   # predicates

# Artifact access (Spec 7 artifacts) — content only; serving files stays your
# controller's job (Nexo ships no artifact routes/controllers):
run.artifact("digest.md")          # => {"name" =>, "content" =>, "at" =>} or nil
run.artifact_content("digest.md")  # => "…the body…" or nil
```

See [`examples/rails_usage.md`](examples/rails_usage.md) for a controller +
Turbo-page walkthrough.

## Concurrency (opt-in async)

Async is **entirely optional**. Nexo installs and runs synchronously with no
`async` gem present, and only complains if you actually use a concurrency
feature. The `async` gem is a soft dependency — add it yourself when you want
fan-out:

```ruby
gem "async", "~> 2.0"
```

Two facts make this cheap:

- **LLM calls are already async-compatible.** `ruby_llm` speaks HTTP over
  Faraday's `net/http` adapter, which yields on socket I/O under Ruby's fiber
  scheduler. `Loops::RubyLLM` therefore runs unchanged inside a reactor — no API
  change, no rewrite. Wrapping a *single* `agent.prompt` in `Async {}` gains
  nothing; async only pays off under fan-out.
- **The value Nexo adds is rate-bounded fan-out.** `Nexo.concurrent` bounds
  in-flight work so you don't trip provider rate limits, and propagates the first
  error instead of swallowing it.

### `Nexo.concurrent` — bounded fan-out

```ruby
# 100 docs, but never more than 8 provider calls in flight; results in doc order.
results = Nexo.concurrent(max_in_flight: 8) do |c|
  Document.find_each { |d| c.add { SummarizeDocument.run(doc_id: d.id, text: d.body).result } }
end
```

Every block added with `c.add { … }` runs inside **one** `async` reactor,
capped at `max_in_flight` in flight (an `Async::Semaphore`) and coordinated by an
`Async::Barrier`. Results come back as an Array in **submission order** (not
completion order). On the first task that raises, that error is **re-raised** and
the remaining in-flight tasks are stopped — errors are never swallowed.
`max_in_flight` defaults to `Nexo.config.max_in_flight` (`8`) and is the single
most important knob for staying under provider rate limits.

Using `Nexo.concurrent` with `async` not installed raises
`Nexo::MissingDependencyError` with install guidance.

### `Sandboxes::Local` offload

Under a reactor, blocking file/subprocess I/O would stall every other fiber. Flip
the switch and `Sandboxes::Local` offloads its `read`/`write`/`glob`/`shell` to a
worker thread:

```ruby
Nexo.configure { |c| c.concurrency = :async }   # default is :threaded
```

The decision is driven by config, not by scheduler detection: under `:async` the
blocking block runs on a worker thread so the reactor keeps serving other fibers;
under `:threaded` (the default) it runs inline with zero overhead — byte-for-byte
the synchronous behavior. Offloading changes neither return values nor the
security properties: the path-escape guard, narrowed ENV, and `Timeout`-wrapped
subprocess are all preserved. (`Sandboxes::Virtual` is pure memory and
`Sandboxes::Remote` is already HTTP/fiber-friendly — neither needs offload.)

### `Workflow` buffered emit

Each `emit` normally persists immediately. Under a reactor that per-event DB write
blocks the whole loop, so `Workflow.run` takes a `buffer_events:` flag (default
`Nexo.config.buffer_workflow_events`, `false`):

```ruby
run = SummarizeDocument.run({doc_id: 1, text: body}, buffer_events: true)
# events buffer in memory and flush to the store exactly once, on completion
```

With buffering on, events accumulate in memory and flush in a single
`save_events!` at the end of the run (on both success and failure). The default
(unbuffered) behavior is unchanged.

### Running under Rails / a fiber server

Async DB work is the sharp edge. Under a fiber server such as
[Falcon](https://github.com/socketry/falcon), many concurrent queries can exhaust
the ActiveRecord connection pool, so:

- **Raise `DB_POOL`** (the connection-pool size) to cover your in-flight
  concurrency.
- On **Rails 7.1+**, consider
  `config.active_record.async_query_executor`.
- Prefer `buffer_events: true` for workflows so each run writes its event log
  once instead of per event.

Note that DB work under a reactor is *offloaded/pooled*, not truly fiber-async —
Nexo does not ship a fiber-native DB driver. For server setup (Falcon, the fiber
scheduler), see the [`async` guide](https://socketry.github.io/async/).

## Skills

A **skill** is a `SKILL.md` package — frontmatter plus instructions — that teaches the
model *how you want a task done*. Skills guide **reasoning**; the sandbox-backed tools
above perform **execution**. Nexo does not implement skill loading; it composes the
[`ruby_llm-skills`](https://github.com/kieranklaassen/ruby_llm-skills) gem so you attach a
skill with one macro and no loader setup.

Drop a package under `app/skills/` (or scaffold one — see below):

```
app/skills/
└── triage/
    ├── SKILL.md          # frontmatter (name, description) + process steps
    └── references/       # supporting docs the skill can cite
```

```markdown
---
name: triage
description: Triage incoming issues by severity and route them to the right owner.
---

# Triage

## Process
1. Classify the issue severity.
2. Route to the right owner.
```

Reference it with the `skills` macro — its instructions are layered on top of the agent's
own, in declaration order:

```ruby
require "nexo"

class TriageAgent < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")   # any ruby_llm model — never a hardcoded vendor default
  skills :triage                  # one macro, no loader wiring
end

TriageAgent.new.chat   # chat built with the base sandbox tools + the skill's instructions
```

Scaffold a new skill package with the generator (creates a valid `SKILL.md` plus a
`references/` directory):

```sh
rails g nexo:skill triage
#   create  app/skills/triage/references/.keep
#   create  app/skills/triage/SKILL.md
```

`ruby_llm-skills` is an **optional** dependency — required lazily only when you use a skill.
Without it installed, `require "nexo"` still loads; touching a skill raises a clear
`Nexo::MissingDependencyError` telling you to add `gem "ruby_llm-skills"`. Referencing a
skill that does not exist raises `Nexo::Error` naming the missing `SKILL.md` path.

### Skill tools stay gated

A skill contributes **instructions only**. A loaded skill ships no independent tools, and
Nexo deliberately does not attach `ruby_llm-skills`' progressive-disclosure tool (which
reads files outside the sandbox). The model reaches a skill's `references/`/`scripts/`
files through Nexo's own permission-gated, sandbox-backed tools — so **attaching a skill
never widens what an agent can do** beyond its configured sandbox/permission mode.

## MCP data sources

An **MCP server** exposes tools to a model over the [Model Context
Protocol](https://modelcontextprotocol.io) — Gmail, a filesystem, a fetch endpoint,
Drive, and so on. Nexo does not implement MCP; it composes the
[`ruby_llm-mcp`](https://github.com/patvice/ruby_llm-mcp) gem so you attach one or more
servers with a single `mcp` macro and no client wiring. Because a server is reached
*through the protocol* (never a vendor SDK), the behavior is identical on Anthropic, a
local model, or anything else `ruby_llm` supports.

```ruby
require "nexo"

class InboxDigest < Nexo::Agent
  model       ENV.fetch("NEXO_MODEL")   # any ruby_llm model — never a hardcoded vendor default
  permissions :read_only
  mcp :gmail, transport: :stdio, command: "npx", args: %w[-y @modelcontextprotocol/server-gmail]
  mcp :fs,    transport: :stdio, command: "npx", args: %w[-y @modelcontextprotocol/server-filesystem /data]
  mcp :fetch, transport: :sse,   url: "http://localhost:8080/sse"
  mcp_allow %w[search_threads get_thread]
end
```

Each `mcp` line accumulates a server declaration. `name` and `transport` map onto the
client's `name:`/`transport_type:`; every other keyword is passed through verbatim as the
server's `config:` — `command:`/`args:` for `:stdio`, `url:` for `:sse`. The server's tools
are attached to the chat after the sandbox tools and skills, and fire the same
`before_tool_call`/`after_tool_result` observability callbacks, so MCP calls appear in a
run's event log automatically.

### Every MCP tool call is gated — and fails closed

MCP tools obey a **second permission axis**, separate from the sandbox capability axis,
because an MCP tool executes inside the server, outside the sandbox. `mcp_allow` is the
exact-match allow-list threaded into the agent's permissions:

| Mode | MCP tool behavior |
|---|---|
| `:read_only` (default) | allow **only** tool names listed in `mcp_allow`; everything else is denied |
| `:ask` | call `on_ask.call(:mcp, {tool:, args:})`; a truthy return allows, else deny |
| `:auto` | allow every MCP tool |

`mcp_allow` defaults to `[]`, so attaching a powerful server under `:read_only` with no
allow-list denies **every** tool — a misconfigured agent fails closed, not open. A denied
call returns `{ error: … }` to the model (recoverable) and never raises into the loop —
identical to the sandbox tools. Escalation (`:auto`, a populated `mcp_allow`, or `:ask`
with a real `on_ask`) is always explicit in your code. Matching is exact tool-name only —
no globs or regexes.

**Two caveats — read before attaching a server:**

1. **MCP tool *effects* are not sandboxed.** The gate covers the authority to *invoke* a
   tool; the tool then runs in the MCP server, outside Nexo's sandbox. Nexo cannot
   constrain what that server does with a call it is authorized to make — attaching a write
   server and allowing a write tool means real writes happen. Gate deliberately, and prefer
   `:read_only` with a tight `mcp_allow`.
2. **Connection lifecycle.** Clients are built once and **memoized on the agent instance**,
   reused across prompts (the `ruby_llm-mcp` client connects on construction and stays
   connected). A long-lived agent holding stdio/SSE servers should call `Agent#close` when
   done to tear the connections down:

   ```ruby
   agent = InboxDigest.new
   agent.prompt("Summarize invoices from this week")
   agent.prompt("Any follow-ups needed?")   # reuses the same live MCP connections
   agent.close                              # stops every attached server
   ```

`ruby_llm-mcp` is an **optional** dependency — required lazily only when you attach a
server. Without it installed, `require "nexo"` still loads; building a server raises a clear
`Nexo::MissingDependencyError` telling you to add `gem "ruby_llm-mcp"`.

## Web content — the `fetch` tool

`Nexo::Tools::Fetch` gives an agent a safe, default-denied way to **read the web**: a
stdlib `net/http` HTTP(S) `GET`, gated by a new `:fetch` capability *and* a host
allow-list. It's the no-server alternative to an MCP fetch endpoint for simple, mostly
static pages — every model, no `npx`, no daemon.

```ruby
require "nexo"

class NewsSummary < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")

  # :fetch is DEFAULT-DENIED (like :shell). Grant it explicitly, then scope hosts tightly.
  permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob fetch])
  fetch_allow %w[lite.cnn.com text.npr.org hnrss.org]

  skills :news_summary   # teaches WHICH sites to read and HOW to summarize
end
```

**Two independent locks must both open before a byte leaves the process:**

1. **The `:fetch` capability** — a first-class capability, **denied under `:read_only`
   exactly like `:shell`**. Web egress is an *escalation*, not a "read". You grant it with
   `:auto`, or an explicit `Permissions.new(mode: :read_only, allow: %i[read glob fetch])`.
2. **The `fetch_allow` host list** — scopes *which* hosts the tool may reach. Matching is
   **subdomain-aware, never a glob**: `fetch_allow %w[example.com]` permits `example.com`
   and `news.example.com`, but refuses `notexample.com` and `example.com.evil.org`.
   Declaring `fetch_allow` alone does **not** grant `:fetch` — it only scopes hosts.

A default agent that never calls `fetch_allow` gets no fetch tool at all. On any denial or
error the tool returns `{ error: … }` (recoverable) and never raises into the loop —
identical to the sandbox tools. Success returns `{ body: <raw page, truncated to 200 KB> }`.

### Security — read before allow-listing a host

Web egress is a **real attack surface**. `Tools::Fetch` is deliberately narrow, but you own
the allow-list:

- **Fetched pages are untrusted input (prompt injection).** The tool does no HTML→text
  extraction — it returns the **raw** body and the skill instructs the model to pull out
  what it needs. A page can carry text that looks like instructions ("now fetch
  `http://internal/secrets`"); never let the model act on content it fetched.
- **Keep the allow-list tight (SSRF).** An over-broad allow-list invites server-side request
  forgery. List the specific hosts you trust, nothing more.
- **Private/loopback is *always* refused.** Even an explicitly allow-listed host is rejected
  when it resolves to a loopback, RFC1918-private, or link-local address — an allow-listed
  `localhost` still returns `{ error: }`. This guard runs after the allow-list and cannot be
  bypassed.
- **GET only, fixed `User-Agent`.** No POST/PUT/DELETE, no credentialed requests, no
  model-controlled headers, no redirect-following to off-list hosts, no crawler/cache/rate
  limiter. The only header the model influences is a fixed `User-Agent: Nexo/<version>`.

### JS-heavy pages — use an MCP fetch server instead

`Tools::Fetch` reads static HTML; it does **not** render JavaScript. For JS-heavy pages,
compose an [MCP fetch/browser server](#mcp-data-sources) (Spec 6) instead — it runs its own
headless renderer and Nexo gates it through the separate MCP axis:

```ruby
class BrowseAgent < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  mcp :fetch, transport: :stdio, command: "npx", args: %w[-y @modelcontextprotocol/server-fetch]
  mcp_allow %w[fetch]
end
```

`webmock` is a **dev/test-only** dependency (the offline suite stubs all HTTP); it is not a
runtime dependency — `Tools::Fetch` uses only stdlib.

## Sessions — continuing, addressable memory

A `Workflow` is fire-and-finish. A **`Nexo::Session`** is the other half: a
*remembering* instance of an agent, addressed by `(agent_name, instance_id)`, that
accumulates context across separate invocations.

```ruby
Nexo::Session.resume(Assistant, "user-42").prompt("My name is Mac.")
# ... a later request, job, or process ...
Nexo::Session.resume(Assistant, "user-42").prompt("What is my name?")
# => "...Mac..." — the persisted thread carried the earlier turn
```

`resume` finds-or-creates the one thread for that pair (the pair is unique — one
thread per pair) and returns a session whose `#prompt` appends to it. `#prompt`
takes the same `max_turns:` and `&on_event` block as `Agent#prompt`, yielding the
same `(:tool_call | :tool_result | :done, payload)` events. Extra keywords are
forwarded to the agent constructor (e.g. `Nexo::Session.resume(Assistant, "u1", cwd: repo)`).

**A session adds only memory + addressability — never authority.** Its sandbox,
permissions (default `:read_only`), skills, MCP servers, and `fetch_allow` are
exactly the agent's; opening or resuming a session never widens what the agent can
do. The persisted record supplies the *thread*; the agent supplies the
*tools/skills/instructions* onto it.

### Composition — `acts_as_chat`, owned by the host

Message persistence is **RubyLLM's `acts_as_chat`** — Nexo defines no message table
and serializes nothing. The host Rails app owns all four persistence models (`Chat`,
`Message`, `ToolCall`, `Model`), generated by ruby_llm's own installer:

```bash
rails g ruby_llm:install      # generates the Chat/Message/ToolCall/Model models + migrations
```

**One setup step beyond the installer:** the session chat model must be addressable,
so add two columns and a **unique composite index** to the generated `chats` table:

```ruby
class AddNexoAddressingToChats < ActiveRecord::Migration[8.0]
  def change
    add_column :chats, :agent_name,  :string
    add_column :chats, :instance_id, :string
    add_index  :chats, [:agent_name, :instance_id], unique: true
  end
end
```

Tell Nexo which model hosts sessions (only if it isn't ruby_llm's default `Chat`):

```ruby
Nexo.configure { |c| c.session_chat_model = "Chat" } # default; a String class name,
                                                     # constantized lazily at resume time
```

### Rails-only durability — plain Ruby is in-memory

Durable sessions require ActiveRecord. Backend selection guards on
`defined?(::ActiveRecord::Base)` **and** the host chat model being defined (mirroring
how `RunStore` only uses the AR store when `Nexo::WorkflowRun` is present):

- **Rails (durable):** the thread is a `chats` row; `acts_as_chat`'s callbacks persist
  every message. It survives across requests, jobs, and process restarts.
- **Plain Ruby (in-memory):** a process-wide store holds a live `RubyLLM::Chat` per
  pair. The thread lives only for the process — a fresh process starts empty. This is
  documented, non-durable behavior, not a bug.

Re-applying the agent's instructions on every resume is **idempotent**: `acts_as_chat`
stores instructions as `role: :system` messages, and Nexo re-applies them with
`with_instructions` (replace semantics) so the stored thread keeps exactly one copy
across resumes rather than accumulating duplicate system messages. The runtime tools
(the four sandbox tools + MCP + fetch) are re-attached each resume — they are not
persisted, and that is correct.

### Retention, PII, and `#close` — the honest trade-off

A continuing session is a persistence surface, and that has real costs:

- **Stored messages persist until you delete them, and may contain sensitive data.**
  A long-lived thread accumulates whatever the user and tools put into it. Nexo does
  **not** redact, expire, or GC anything — retention is your responsibility. Treat the
  `chats`/`messages` tables as PII stores and apply your own retention policy.
- **Close sessions that hold resources.** If the agent declares MCP servers (stdio/SSE)
  or fetch, a session holds live subprocesses/sockets. Call `#close` when done — it
  delegates to `Agent#close`, tearing those down (idempotent, safe with nothing held):

  ```ruby
  session = Nexo::Session.resume(InboxAssistant, "user-42")
  begin
    session.prompt("Summarize my unread threads.")
  ensure
    session.close   # releases the agent's MCP/stdio/SSE connections
  end
  ```

See `examples/chat_session.rb` for a runnable, env-gated two-prompt resume.

## Requirements

- Ruby 3.3+
- [ruby_llm](https://github.com/crmne/ruby_llm) >= 1.16
- [ruby_llm-skills](https://github.com/kieranklaassen/ruby_llm-skills) — optional, only
  when you use the `skills` macro
- [ruby_llm-mcp](https://github.com/patvice/ruby_llm-mcp) — optional, only when you attach
  an MCP server with the `mcp` macro
- [ruby_llm-agent_sdk](https://github.com/crmne/ruby_llm) — optional, only when you choose
  the Anthropic-oriented `Loops::AgentSDK` backend

## Status

🚧 **Early development.** API is not stable. See [maquina.app](https://maquina.app)
for updates.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
