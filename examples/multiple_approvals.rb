# frozen_string_literal: true

# Several calls waiting for approval at once, answered by key.
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/multiple_approvals.rb
#
# Under `:approve` a call nobody has decided is held before the tool runs, and
# the run suspends. A model response can ask for more than one gated call:
# `run.state["__approvals_pending__"]` lists every one with the key to answer it
# under, and `resume(id, approvals: {key => true | false})` answers them together.
require "nexo"
require "tmpdir"
require_relative "support/model"

WORKSPACE = Dir.mktmpdir("nexo-approvals")

class Publisher < Nexo::Agent
  Examples.model(self)
  permissions :approve
  instructions "You write files with the write_file tool when asked. Do not ask for confirmation."
end

class PublishNotes < Nexo::Workflow
  cwd WORKSPACE
  sandbox :local
  agent Publisher

  def call(_payload)
    {reply: run_agent("Create two files: public.md containing 'release notes' and " \
                      "secret.md containing 'internal only'. Write both now.").content}
  end
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  run = PublishNotes.run
  # A host answers until the run stops asking: a model may ask for both writes in
  # one response, or one at a time, or phrase the second attempt differently.
  5.times do
    break unless run.status == "suspended"

    pending = run.state["__approvals_pending__"]
    puts "waiting for a decision on #{pending.size} call(s):"
    answers = pending.to_h do |call|
      approved = !call["tool"].to_s.include?("secret") # this "human" refuses the secret file
      puts "  #{approved ? "approve" : "decline"}  #{call["capability"]} #{call["tool"]}"
      [call["key"], approved]
    end
    run = Nexo::Workflow.resume(run.id, approvals: answers)
  end

  puts "status:    #{run.status}"
  puts "reply:     #{run.result && run.result["reply"]}"
  puts "on disk:   #{Dir.children(WORKSPACE).sort.inspect}  (secret.md was declined)"
end
