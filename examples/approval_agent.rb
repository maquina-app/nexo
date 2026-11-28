# frozen_string_literal: true

# Verification example — Spec 16 (Durable Approval): bridge an agent's :approve
# gate to a durable suspend/resume.
#
# The workflow drives an agent under the :approve permission mode. The moment the
# agent tries a sensitive capability (a write) the gate raises
# Nexo::ApprovalRequired, which propagates out of the tool loop; run_agent catches
# it, records the pending call under run.state["__approval__"], and SUSPENDS the
# run (a background worker returns — nothing blocks). Later, a host approves and
# resumes: the decision is threaded into the agent, the same gate now ALLOWS, and
# the run completes.
#
# This needs a live tool-calling model (the agent must actually decide to write),
# so it is env-gated:
#
#   NEXO_LIVE=1 NEXO_MODEL=gpt-4o-mini OPENAI_API_KEY=... ruby -Ilib examples/approval_agent.rb
#
# Nothing provider-specific: set NEXO_MODEL to any ruby_llm-supported tool-calling
# model. Offline, the same bridge is exercised by test/workflow_approval_test.rb
# with a spy agent (no API key, no network).
#
# In a real host app you would use the ActiveRecord store (`rails g nexo:workflows`)
# so the suspended run survives across processes, and resume from a controller/job
# once a human clicks "approve" (`MyWorkflow.resume_later(run.id, approved: true)`).
require "nexo"
require "tmpdir"
require_relative "support/model"

# A local sandbox in a throwaway directory — the agent writes a file the model
# chooses; :approve gates that write for a human decision.
WORKSPACE = Dir.mktmpdir("nexo-approval")
class Scribe < Nexo::Agent
  Examples.model(self, default: "gpt-4o-mini")
  sandbox :local
  permissions :approve # every write/shell needs a human decision (undecided ⇒ suspend)
  instructions "You write short files when asked. Use the write_file tool."
end

class ApprovedWrite < Nexo::Workflow
  cwd WORKSPACE # not the directory you run this from
  sandbox :local
  agent Scribe

  def call(_payload)
    resp = run_agent("Write the text 'approved!' to notes/approval_demo.txt")
    {content: resp.content}
  end
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  # 1) First pass: the agent hits the :approve gate on its write → the run suspends.
  run = ApprovedWrite.run
  puts "status after first pass:  #{run.status}"                       # => "suspended"
  puts "suspend reason:           #{run.state["__suspend__"]["reason"]}"
  puts "pending approval:         #{run.state["__approval__"].inspect}" # capability/tool/args

  # 2) A human approves. Resume threads {approved: true} into the agent, so the
  #    same gate now allows and the run completes. (Denying — resume(approved:
  #    false) — instead has the call refused; the model adapts and the run still
  #    completes "done", without the write.)
  #
  #    One answer decides one call, and a resume asks the model again: if it asks
  #    for something different this time, that is a new call and the run suspends
  #    for it. So a host answers until the run stops asking.
  resumed = ApprovedWrite.resume(run.id, approved: true)
  2.times do
    break unless resumed.status == "suspended"

    puts "asked again for:          #{resumed.state["__approval__"].inspect}"
    resumed = ApprovedWrite.resume(resumed.id, approved: true)
  end
  puts "status after resume:      #{resumed.status}"                    # => "done"
  puts "result:                   #{resumed.result.inspect}"
  puts "written:                  #{File.join(WORKSPACE, "notes/approval_demo.txt")}"
end
