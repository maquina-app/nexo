# Durable workflows — suspend · checkpoint · resume
A long-running or human-in-the-loop workflow can pause durably and continue later without re-running already-paid-for work.

A long-running or human-in-the-loop workflow can **pause durably** and **continue
later** — possibly in another process — without re-running completed,
already-paid-for work. Three small primitives compose over the existing run
persistence (no step-graph engine, no replay log, no scheduler):

- **`checkpoint(name) { … }`** runs its block **once** and stores the
  json-serializable result under `name` in the run's `state`. On a later run/resume
  of the *same* run, a present checkpoint returns the stored value **without**
  re-running the block. This is the tool that makes resume cheap and side-effect-safe.
- **`suspend!(reason:, resume_key: nil)`** pauses the run: it marks the run
  `"suspended"` (a **non-failure** outcome, distinct from `"failed"`) and returns it
  to the caller — `Workflow.run` does **not** raise. Call it *outside* a checkpoint.
- **`Workflow.resume(run_id, input = {})`** (sync) and
  **`Workflow.resume_later(run_id, input = {})`** (enqueued) continue a suspended
  run, feeding `input` in as `#resume_input`.

```ruby
class DocumentApproval < Nexo::Workflow
  def call(payload)
    document = checkpoint(:fetch) { fetch_expensive(payload[:id]) } # paid for once

    # `resume_input` is {} on the first pass, so we pause; on resume the host
    # feeds { approved: true }, so we fall through and publish.
    suspend!(reason: "awaiting approval") unless resume_input[:approved]

    checkpoint(:publish) { publish!(document) }
    { done: true }
  end
end

run = DocumentApproval.run(id: 42)   # reaches suspend!, returns
run.status                            # => "suspended"
run.suspend_reason                    # => "awaiting approval"  (AR store)
run.state["fetch"]                    # => the fetched document (checkpoint persisted)

# ...later, once a human approves — possibly in another process:
resumed = DocumentApproval.resume(run.id, approved: true)
resumed.status                        # => "done"  (the :fetch block did NOT re-run)
```

A host UI lists paused runs with the `suspended` scope and inspects them with the
readers (Nexo ships no controllers/views — the UI is your app's job):

```ruby
Nexo::WorkflowRun.suspended            # scope: all paused runs
run.suspended?                          # => true
run.suspend_reason                      # => "awaiting approval"
run.checkpoint_result(:fetch)           # => the stored :fetch value, or nil
```

For a **durable, cross-process** resume from a background job, enqueue it — the job
carries the run id plus the (json-safe) resume input; the payload still lives on the
run:

```ruby
# The resume input is a positional Hash (queue: is the only keyword), so pass it
# as `{ approved: true }` — bare `approved: true` would bind as an unknown keyword.
DocumentApproval.resume_later(run.id, { approved: true }, queue: :nexo)
```

See [`examples/approval_workflow.rb`](https://github.com/maquina-app/nexo/blob/main/examples/approval_workflow.rb) for the full
offline flow (`ruby -Ilib examples/approval_workflow.rb`).

## Parallel checkpoints — `checkpoint_all`

When several checkpoints are **independent** (no step depends on another's
result), run them concurrently with `checkpoint_all(name => callable, …)` instead
of a sequence of `checkpoint` calls. It fans the pending steps out through
[`Nexo.concurrent`](concurrency.md) — all in flight at once — and persists **each
step as it completes** (not the batch as a whole), so a resume after a partial
failure only re-runs the steps that never landed:

```ruby
class BuildDashboard < Nexo::Workflow
  def call(payload)
    data = checkpoint_all(
      account: -> { fetch_account(payload[:id]) },   # these two run
      usage:   -> { fetch_usage(payload[:id]) }      # concurrently
    )
    { report: render(data[:account], data[:usage]) }
  end
end
```

`checkpoint_all` returns a Hash keyed by the **original** names you passed
(`data[:account]`), with values read back from `state` — the same shape whether a
value came from this pass or a prior one. Each newly-completed step also surfaces a
`"checkpoint"`-typed event on the run's event log and the `nexo.workflow.event`
notification (data is the step **name** only, never the value — so a dashboard can
show batch progress without the event log carrying large or sensitive results).
Steps already present in `state` are skipped silently and emit nothing.

Bound the batch by how many keys you pass — there is no separate rate knob; every
pending step goes in flight. Because it drives `Nexo.concurrent`, `checkpoint_all`
needs the `async` gem **only when something is actually pending** — an
all-persisted pass (every step already done) returns the prior values directly
without touching concurrency. The same restrictions as `checkpoint` apply: values
must be json-serializable, a step must **not** be named after a reserved state key
(`__suspend__`/`__approval__`/`__buffer_events__` — raises `Nexo::Error` before any
step runs), and do **not** call `suspend!` inside a step (undefined — unsupported).

> **⚠️ Known trade-off: per-step persistence, not an atomic batch.** `checkpoint_all`
> is **not** transactional. If step B raises after step A persisted, A stays in
> `state`, B is absent, the run goes `"failed"`, and the exception propagates through
> the workflow's normal failure path (`Nexo.concurrent`'s "first failure re-raises,
> the rest stop" — it is not rescued away). A subsequent `execute` of the **same** run
> re-submits only the still-missing names — A is skipped, B re-runs. Do **not** treat
> a batch as all-or-nothing.

## Run a failed run again — `Workflow.retry`

`resume` continues a run that paused on purpose. `retry` (0.16) does the same for one that
stopped by accident: a run that raised (`"failed"`), or one whose process died
(`"interrupted"`). It re-enters `#call` from the top with the original payload, and every
checkpoint the run finished before it stopped is returned from its state — including the
finished steps of a `checkpoint_all` batch.

```ruby
begin
  run = Triage.run(inbox: "work")
rescue => e
  # three inboxes were read and checkpointed; building the digest raised
end

Triage.retry(run_id)   # reads no inbox again; goes straight back to the digest
```

The run keeps its id, its events and its artifacts; its `error` is cleared when the retry
starts. A retry that fails again leaves the run `"failed"` and re-raises, and can be retried
again. Any other status raises `Nexo::Error`.

A process that is killed leaves its run `"running"`. `Nexo::Workflow.reconcile_interrupted!`
marks those `"interrupted"` — call it once at boot, or before offering a retry. Since 0.16
it covers the Disk run store as well as ActiveRecord and the in-memory one; before that a CLI
on the Disk store that was killed mid-run could never be picked up.

Like `resume`, this is re-entry, not replay: code outside a checkpoint runs again.

## Stop a run — `Workflow.cancel`

```ruby
Nexo::Workflow.cancel(run_id)
```

- A run that is not executing (`"pending"`, `"queued"`, `"suspended"`) becomes `"cancelled"` at
  once, and a queued job that later picks it up does nothing.
- A `"running"` run is **asked** to stop. The request is left in the run store, and the process
  executing the run sees it at its next `checkpoint`, at the start of a `run_agent`, or around
  the agent's next tool call. It then ends `"cancelled"`. The model request in flight finishes
  first, so stopping takes as long as that request.

Nothing is rolled back: events, artifacts and finished checkpoints stay, and what the agents
used up to that point is still recorded. A cancelled run is final — it can be neither resumed
nor retried. Cancelling a run that already ended raises `Nexo::Error`.

It works across processes on the ActiveRecord store (the run reads `"cancelling"` until it
stops) and on the Disk store (an empty `<id>.cancel` file beside the run's document). A run
store of your own needs `request_cancel!(run)`, `cancel_requested?(run)` and `clear_cancel!(run)`.

Code outside a checkpoint and outside `run_agent` is not interrupted. A long step of your own
can ask `cancel_requested?` and return early.

## What a run used — `Workflow.usage`

Every `run_agent` records an `agent_usage` event with the tokens and cost its prompt added.
A workflow that prompts its agents itself records the same events with
`emit_agent_event` (0.16.1):

```ruby
agent = Reviewer.new(sandbox: sandbox)
agent.prompt(text, cancel: -> { cancel_requested? }) do |type, payload|
  emit_agent_event(type, payload, "source" => "reviewer")   # the tag is yours
end
```

`Nexo::Workflow.usage(run)` totals them:

```ruby
Nexo::Workflow.usage(run)
# => {"tokens" => {"input_tokens" => 18_230, "output_tokens" => 2_114}, "cost" => 0.0412, "prompts" => 3}
```

`"cost"` is `nil` when any prompt ran on a model `ruby_llm` has no price for (a local model,
say): a partial total would read as the whole bill. A retried or resumed run adds to the same
log, so the total is what the run cost altogether.

## A tool that asks the person — suspend, answer, resume

When a tool the agent calls asks the person something (an MCP server's question, or a
`RubyLLM::Tool` calling `ask`), `run_agent` suspends the run, exactly as it does for an
approval. The questions are in the run's state:

```ruby
run = Booking.run(user_id: 7)
run.status                    # => "suspended"
run.state["__input__"]
# => [{"key" => "book:seat", "tool" => "book", "message" => "Window or aisle?",
#      "fields" => [{"name" => "seat", "type" => "string", "required" => true}]}]

Booking.resume(run.id, answers: {"book:seat" => "aisle"})
```

Answers accumulate on the run (`"__answers__"`), like approvals: a later, different question
suspends it again. Resume re-runs the prompt, so the model has to ask for the tool again; when
it does, the stored answer is sent and the turn carries on. An answer for a key that was not
asked is ignored.

## Durable **agent** approval — `:approve` (bridge a mid-run gate to a suspend)

The example above suspends at an **explicit** `suspend!` the workflow author placed.
The `:approve` mode adds the durable, cross-process sibling of `:ask` for the case where a
`run_agent`-driven agent hits a permission gate **mid-loop** and you want that to
**pause the run for a human**, not run unchecked and not block a worker. Declare the
agent under the `:approve` mode:

```ruby
class Scribe < Nexo::Agent
  model   ENV.fetch("NEXO_MODEL")
  sandbox :local
  permissions :approve        # every gated capability needs a human decision
end

class ApprovedWrite < Nexo::Workflow
  sandbox :local
  agent   Scribe
  def call(_p) = { content: run_agent("Write 'hi' to notes.txt").content }
end
```

The loop is: **`:approve` gate reaches a call nobody has decided → `Nexo::ApprovalRequired` → `run_agent`
suspends → host renders the pending call → `resume(approved:)` threads the decision back
through the gate.**

```ruby
run = ApprovedWrite.run                       # agent reaches the write gate, run suspends
run.status                                     # => "suspended"
run.state["__suspend__"]["reason"]             # => "approval: notes.txt"
run.state["__approval__"]                      # => { "capability" => "write",
                                               #      "tool" => "notes.txt", "args" => nil }
# "args" carries the tool call arguments only for an MCP-tool approval; a sandbox
# capability gate (write/shell/fetch/search) records "args" => nil — the pending
# call is identified by "capability" + "tool".

# ...a human approves — possibly in another process (resume_later for the AR store):
resumed = ApprovedWrite.resume(run.id, approved: true)
resumed.status                                 # => "done" (the gate allowed the write)
```

- **The pause is `ruby_llm`'s own (0.16).** Before a tool runs, `ruby_llm` asks it whether
  the call needs approval and what was decided; Nexo's tools answer both from the agent's
  `Permissions` (`Nexo::Approvable`). An undecided call is held **before the tool is entered**,
  and `Agent#prompt` raises `Nexo::ApprovalRequired`, which `run_agent` turns into the suspend.
  Before 0.16 the signal was an exception raised inside the tool, so a host's catch-all
  `rescue_from StandardError` on a tool swallowed it. That can no longer happen.
- **`Nexo::ApprovalRequired`** is a signal, **distinct from `Permissions::Denied`**:
  `Denied` means "no, adapt"; `ApprovalRequired` means "pause and ask a human".
- **Every waiting call is listed.** A model response can ask for several gated calls at
  once. `run.state["__approvals_pending__"]` lists each one (`"capability"`, `"tool"`,
  `"args"`, `"key"`); `"__approval__"` is still the first. Answer several in one resume with
  `resume(run.id, approvals: {key => true, other_key => false})`; `approved: true` answers
  the first, as before. A key that was not pending is ignored.
- **A tool of your own that declares `requires_approval`** (the `ruby_llm` macro) is decided
  the same way, under the capability `tool`.
- **Undecided ⇒ suspend, `approved: false` ⇒ deny.** The default stays safe: an
  unresolved approval never silently allows, and a denial on resume has `ruby_llm` answer the
  call with a refusal (the model adapts) — the run still finishes `"done"`, **without** the gated
  effect, never `"failed"`.
- **Scope which actions need approval** with the same `ask_when` predicate as `:ask` —
  unset means every gated action needs a decision; a falsey predicate auto-allows without
  one. (The `approve_when:` alias was removed in 0.16.)

  ```ruby
  Nexo::Permissions.new(mode: :approve,
    ask_when: ->(cap, detail) { cap == :write && detail.to_s.start_with?("/protected") })
  ```
- **Synchronous `:ask` is untouched.** `:ask` (in-process `on_ask`) is still the right
  choice with a human at the keyboard during a synchronous `run`; `:approve` is its
  durable, cross-process sibling for `run_later`/`resume_later`.

**Caveats (read before relying on it):**
- **Re-entry, not replay.** On resume the agent re-drives `#call` from the top; a
  non-idempotent tool call *before* the approval gate re-runs on resume (agent tool calls
  generally aren't checkpointable). Put approval gates **early**, or after the expensive
  work is already `checkpoint`ed by the workflow.
- **One answer decides one call.** `resume(approved:)` answers the call recorded under
  `run.state["__approval__"]`, and nothing else. The answer is filed in
  `run.state["__approvals__"]` under that call's key (capability plus path, command or URL; for
  an MCP tool, its name plus a digest of the arguments). A *different* gated call later in the
  same prompt **suspends again**, and the next resume decides it. Before 0.14 the first answer
  silently applied to every later call.
- **A re-driven model may ask for something else.** Resume runs the prompt again, and nothing
  forces the model to repeat the call you approved. If it writes `b.txt` where it asked for
  `a.txt`, that is a new call and the run suspends for it. This is the safe direction.
- **`approved:` with nothing pending approves nothing.** An answer is recorded only when a call
  is waiting.
- **Cross-process approval needs the ActiveRecord store + ActiveJob** (like all durable resume).
  In-process `resume` works with the Memory store; a Memory run does not survive the process.
- **It depends on `ruby_llm`'s approval hooks.** The chat asks the registered tool
  `requires_approval?(tool_call)` and reads its `approval_resolver` (verified on 2.2.3 through
  the real loop, `test/approval_pause_test.rb`). Nexo's wrapper around a tool is not a
  `RubyLLM::Tool`, so this relies on `ruby_llm` calling those two methods on whatever was
  attached — a genuine upstream dependency, stated plainly. The gate inside each tool is the
  net under it: a call that got through undecided is still refused there.

See [`examples/approval_agent.rb`](https://github.com/maquina-app/nexo/blob/main/examples/approval_agent.rb) for the live flow
(`NEXO_LIVE=1 NEXO_MODEL=… ruby -Ilib examples/approval_agent.rb`).

The `state` column ships with fresh installs. Apps installed before this feature
add it with an additive migration:

```sh
rails g nexo:state
rails db:migrate
```

## Honest resume semantics — read this before relying on resume

Resume **re-enters `#call` from the top** — Ruby has no transparent continuation
capture, so this is **not** replay:

- **Everything *outside* a `checkpoint` re-runs on resume.** Only checkpoint-guarded
  work is skipped (its stored result is returned). Wrap every expensive step and
  every side effect in a `checkpoint`; the idempotency of the non-checkpointed code
  is **your** responsibility.
- **A crash *inside* a checkpoint re-runs that checkpoint** on resume (at-least-once
  for the in-flight step) — so a checkpoint's side effect should tolerate being
  retried.
- **Checkpoint values must be json-serializable** — they round-trip the store exactly
  like `result`/`events`.
- **Cross-process resume needs the ActiveRecord store.** A run suspended under the
  in-memory store resumes only *in-process* (which is what the test suite exercises);
  a run that must survive the process (and be resumed by a controller/job elsewhere)
  needs the AR store with a shared database.
- **Never `suspend!` inside a `checkpoint` block** (undefined — unsupported), and
  never name a checkpoint `"__suspend__"` (reserved for the suspend metadata) or
  `"__approval__"` (reserved for the pending approval call — see the durable-approval
  section above) — both are keys Nexo stores in `state`.

There is **no distinct `"resumed"` status**: resume re-enters `execute`, so a host
sees the existing `suspended` → `running` → `done` (or `suspended` again)
transitions over the usual `nexo.workflow.status` notifications. The boot
`reconcile_interrupted!` sweep leaves `"suspended"` runs **untouched** — an
intentional pause is never mistaken for an orphaned `"running"` run.

← Back to the [README](../README.md)
