# frozen_string_literal: true

# A team of specialists working one brief at the same time, and an editor who
# puts their work together. (After Eve's "Marketing team" template.)
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/marketing_team.rb
#
# Eve routes with a lead agent and subagents. Nexo has no subagents: who does what
# is plain Ruby in a workflow, which is also what makes it resumable.
# `checkpoint_all` runs the three specialists concurrently and saves each result
# as it lands, so a run that fails in the editor step does not pay for the
# specialists again on `Nexo::Workflow.retry`.
require "nexo"
require_relative "support/model"

class Specialist < Nexo::Agent
  Examples.model(self)
  file_tools :none # they write copy; they need no files and get no tools
end

class Positioning < Specialist
  instructions "You write product positioning. Given a brief, reply with one positioning statement and three proof points. No preamble."
end

class Social < Specialist
  instructions "You write social posts. Given a brief, reply with three short posts for developers, each under 240 characters. No hashtags, no preamble."
end

class Email < Specialist
  instructions "You write launch emails. Given a brief, reply with a subject line and a body of at most 90 words. No preamble."
end

class Editor < Specialist
  instructions "You are an editor. You receive drafts from three specialists. Make them agree with each other, " \
               "remove anything the brief does not support, and return one markdown document with the sections " \
               "Positioning, Social and Email."
end

class LaunchCampaign < Nexo::Workflow
  TEAM = {"positioning" => Positioning, "social" => Social, "email" => Email}.freeze

  def call(payload)
    brief = payload[:brief]

    # Three model calls in flight at once; each result is a checkpoint of its own.
    drafts = checkpoint_all(TEAM.transform_values { |specialist| -> { ask(specialist, brief) } })

    campaign = checkpoint(:edit) do
      ask(Editor, "Brief:\n#{brief}\n\n" + drafts.map { |name, draft| "## #{name}\n#{draft}" }.join("\n\n"))
    end

    artifact("campaign.md", content: campaign)
    {sections: drafts.keys}
  end

  private

  def ask(agent_class, text)
    agent = agent_class.new
    agent.prompt(text).content
  ensure
    agent&.close
  end
end

BRIEF = <<~TXT
  Product: Nexo 0.16, an open-source Ruby gem for building AI agents on ruby_llm.
  What is new: agents get file tools gated by permissions, a failed run can be
  retried without repeating finished steps, and a run reports the tokens it used.
  Install: gem "nexo_ai" in the Gemfile.
  Audience: Ruby and Rails developers. Tone: plain, no hype.
TXT

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  run = LaunchCampaign.run(brief: BRIEF)
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

  puts "status:      #{run.status} in #{elapsed.round(1)}s"
  puts "checkpoints: #{(run.state.keys - Nexo::Workflow::RESERVED_STATE_KEYS).inspect}"
  puts
  puts Nexo::Workflow.artifact_body(run.artifacts.find { |artifact| artifact["name"] == "campaign.md" })
end
