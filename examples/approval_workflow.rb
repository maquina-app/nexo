# frozen_string_literal: true

# Verification example — Spec 13: a durable human-in-the-loop (HITL) workflow.
#
# The workflow fetches a document (an expensive/side-effectful step, guarded by a
# `checkpoint` so it is paid for exactly once), then `suspend!`s to wait for a human
# approval. Later — possibly in another process — a controller/job calls
# `Workflow.resume(run_id, approved: true)`; the workflow re-enters `#call` from the
# top, SKIPS the already-completed `:fetch` checkpoint, and publishes.
#
# Fully offline (Memory store, in-process resume) — no API key, no network:
#
#   ruby -Ilib examples/approval_workflow.rb
#
# In a real host app you would use the ActiveRecord store (`rails g nexo:workflows`)
# so the suspended run survives across processes, suspend from a controller action,
# and resume from a different request/job once a human clicks "approve".
require "nexo"

class DocumentApproval < Nexo::Workflow
  def call(payload)
    # Expensive/side-effectful: fetched once, then reused on resume. A crash before
    # suspend would re-run it (at-least-once); a crash after suspend never re-fetches.
    document = checkpoint(:fetch) do
      emit(:fetching, id: payload[:id])
      "contents of document ##{payload[:id]}"
    end

    # Gate on the resume input. On the first pass it is `{}`, so we pause the run.
    # On resume the host feeds `{approved: true}`, so we fall through and publish.
    unless resume_input[:approved]
      emit(:awaiting_approval, id: payload[:id])
      suspend!(reason: "awaiting human approval", resume_key: "doc-#{payload[:id]}")
    end

    published = checkpoint(:publish) do
      emit(:publishing, id: payload[:id])
      "published: #{document}"
    end

    {published: published, approved_by: resume_input[:approver]}
  end
end

if __FILE__ == $PROGRAM_NAME
  # 1) A controller kicks off the run. It reaches `suspend!` and returns paused.
  run = DocumentApproval.run(id: 42)
  puts "status after first pass:  #{run.status}"           # => "suspended"
  puts "suspend reason:           #{run.state["__suspend__"]["reason"]}"
  puts "fetch checkpoint stored:  #{run.state["fetch"].inspect}"

  # 2) Time passes; a human approves. A LATER request/job resumes the run, feeding
  #    the approval in as `input`. #call re-runs from the top but skips :fetch.
  resumed = DocumentApproval.resume(run.id, approved: true, approver: "alice")
  puts "status after resume:      #{resumed.status}"       # => "done"
  puts "result:                   #{resumed.result.inspect}"
  puts "publish checkpoint:       #{resumed.state["publish"].inspect}"

  # The event log shows :fetching fired ONCE (checkpoint skipped on resume) while
  # :publishing fired on the resume pass.
  puts "events:                   #{resumed.events.map { |e| e["type"] }.inspect}"
end
