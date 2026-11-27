# frozen_string_literal: true

# What a prompt and a run used: tokens by kind, and the cost when ruby_llm has a
# price for the model.
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/usage_report.rb
#
# The loop emits `:usage` once per prompt, last, even when the prompt raises. A
# workflow records it, and `Nexo::Workflow.usage(run)` totals a run.
require "nexo"
require_relative "support/model"

class Explainer < Nexo::Agent
  Examples.model(self)
  instructions "Answer in two sentences."
end

class TwoQuestions < Nexo::Workflow
  agent Explainer

  def call(_payload)
    first = run_agent("What is a checkpoint in a long-running job?")
    second = run_agent("And why does it matter when the job fails halfway?")
    {answers: [first.content, second.content]}
  end
end

def show(label, usage)
  tokens = usage[:tokens] || usage["tokens"]
  cost = usage[:cost] || usage["cost"]
  puts "#{label.ljust(18)} #{tokens.map { |kind, count| "#{kind}=#{count}" }.join("  ")}  cost=#{cost ? format("$%.4f", cost) : "unknown (no price for this model)"}"
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  # 1) One prompt: the block receives :usage after :done.
  Explainer.new.prompt("What is a mutex?") do |type, payload|
    show("one prompt:", payload) if type == :usage
  end

  # 2) A run: each run_agent records an agent_usage event; usage totals them.
  run = TwoQuestions.run
  run.events.select { |event| event["type"] == "agent_usage" }.each_with_index do |event, index|
    show("run, prompt #{index + 1}:", event["data"])
  end
  total = Nexo::Workflow.usage(run)
  show("run total:", total)
  puts "prompts in the run: #{total["prompts"]}"
end
