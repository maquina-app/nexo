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
DocumentApproval.resume_later(run.id, approved: true, queue: :nexo)
```

See [`examples/approval_workflow.rb`](../examples/approval_workflow.rb) for the full
offline flow (`ruby -Ilib examples/approval_workflow.rb`).

## Durable **agent** approval — `:approve` (bridge a mid-run gate to a suspend)

The example above suspends at an **explicit** `suspend!` the workflow author placed.
Spec 16 adds the durable, cross-process sibling of `:ask` for the case where a
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

The loop is: **`:approve` gate with no decision → `Nexo::ApprovalRequired` → `run_agent`
suspends → host renders the pending call → `resume(approved:)` threads the decision back
through the gate.**

```ruby
run = ApprovedWrite.run                       # agent reaches the write gate, run suspends
run.status                                     # => "suspended"
run.state["__suspend__"]["reason"]             # => "approval: notes.txt"
run.state["__approval__"]                      # => { "capability" => "write",
                                               #      "tool" => "notes.txt", "args" => {…} }

# ...a human approves — possibly in another process (resume_later for the AR store):
resumed = ApprovedWrite.resume(run.id, approved: true)
resumed.status                                 # => "done" (the gate allowed the write)
```

- **`Nexo::ApprovalRequired`** is a signal, **distinct from `Permissions::Denied`**:
  `Denied` means "no, adapt" (tools rescue it into `{error:}`); `ApprovalRequired` means
  "pause and ask a human", so tools must **not** rescue it — it propagates out of the
  tool loop and out of `Agent#prompt`, where `run_agent` catches it.
- **Undecided ⇒ suspend, `approved: false` ⇒ deny.** The default stays safe: an
  unresolved approval never silently allows, and a denial on resume makes the tool return
  `{error:}` (the model adapts) — the run still finishes `"done"`, **without** the gated
  effect, never `"failed"`.
- **Scope which actions need approval** with the same `ask_when` predicate as `:ask`
  (aliased `approve_when:` for readability) — unset means every gated action needs a
  decision; a falsey predicate auto-allows without one:

  ```ruby
  Nexo::Permissions.new(mode: :approve,
    approve_when: ->(cap, detail) { cap == :write && detail.to_s.start_with?("/protected") })
  ```
- **Synchronous `:ask` is untouched.** `:ask` (in-process `on_ask`) is still the right
  choice with a human at the keyboard during a synchronous `run`; `:approve` is its
  durable, cross-process sibling for `run_later`/`resume_later`.

**Caveats (read before relying on it):**
- **Re-entry, not replay.** On resume the agent re-drives `#call` from the top; a
  non-idempotent tool call *before* the approval gate re-runs on resume (agent tool calls
  generally aren't checkpointable). Put approval gates **early**, or after the expensive
  work is already `checkpoint`ed by the workflow.
- **One approval per suspend cycle, global decision.** The `{approved:}` answers whichever
  gate the re-driven agent hits first. A *second* gate after an approved first one simply
  **suspends again** — the next resume decides it. There is no per-tool decision granularity
  in v1.
- **Cross-process approval needs the ActiveRecord store + ActiveJob** (like all of Spec 13).
  In-process `resume` works with the Memory store; a Memory run does not survive the process.
- **Branch depends on upstream `ruby_llm`.** This works because `ruby_llm`'s tool loop lets a
  tool `execute` exception propagate out of `chat.ask` (verified, 1.16.0). If a future
  `ruby_llm` swallows tool exceptions, tool-triggered approval would be constrained — a
  genuine upstream dependency, stated plainly.

See [`examples/approval_agent.rb`](../examples/approval_agent.rb) for the live flow
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
