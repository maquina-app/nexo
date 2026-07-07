# frozen_string_literal: true

# The five-line agent, pointed at a LOCAL model via Ollama — plus a skill and
# per-prompt token accounting. Runs against any ruby_llm-supported model; nothing
# here is vendor-specific.
#
#   NEXO_MODEL=gemma3:12b ruby -Ilib examples/code_reviewer.rb
#
# `provider :ollama` + `assume_model_exists true` skip ruby_llm's models.json
# registry lookup so unregistered local tags (gemma3:12b, self-hosted builds)
# work without waiting for a registry update.
require "bundler/setup"
require "nexo_ai"

RubyLLM.configure do |config|
  # Ollama itself needs no key; set API_KEY only if a local proxy requires one.
  config.ollama_api_key = ENV["API_KEY"] if ENV["API_KEY"]
  config.ollama_api_base = ENV.fetch("OLLAMA_API_BASE", "http://127.0.0.1:11434/v1")
end

Nexo.configure do |config|
  config.skills_path = File.expand_path("skills", __dir__)
end

class CodeReviewer < Nexo::Agent
  model ENV.fetch("NEXO_MODEL") # any ruby_llm-supported model; e.g. gemma3:12b
  provider :ollama
  assume_model_exists true
  sandbox :virtual # in-memory: the agent reads only what we stage below
  permissions :read_only

  instructions "You are a careful code reviewer. Read files and report issues. Do not write files."
  skills "ruby-code-review" # examples/skills/ruby-code-review/SKILL.md
end

if __FILE__ == $PROGRAM_NAME
  agent = CodeReviewer.new

  totals = Hash.new(0)
  show_stats = ->(response) do
    totals[:input] += response.input_tokens.to_i
    totals[:output] += response.output_tokens.to_i
    puts "— #{response.model_id}: in=#{response.input_tokens} out=#{response.output_tokens}"
  end

  # Stage this very file into the agent's in-memory sandbox: the review target.
  puts "Staging code_reviewer.rb into the sandbox"
  agent.sandbox.write("code_reviewer.rb", File.read(__FILE__))

  puts "\nReviewing file"
  response = agent.prompt("Review the code_reviewer.rb file")
  puts response.content
  show_stats.call(response)

  # Deliberate denial demo: :read_only means the write tool refuses, so the model
  # must report that it cannot delete/modify anything.
  puts "\nAsking for a delete (expected to be refused under :read_only)"
  response = agent.prompt("Delete file code_reviewer.rb")
  puts response.content
  show_stats.call(response)

  puts "-----"
  puts "Session totals: in=#{totals[:input]} out=#{totals[:output]} total=#{totals[:input] + totals[:output]}"
end
