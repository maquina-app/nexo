# frozen_string_literal: true

# The `llm` block: ruby_llm's own agent options on a Nexo agent — here a
# fallback model, a temperature and a context budget.
#
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/llm_options.rb
#
# The primary model below points at a server that is not there, so the request
# fails to connect and ruby_llm moves to the fallback: the model you named. The
# loop reports it as a `:fallback` event.
require "nexo"
require_relative "support/model"

abort "set NEXO_PROVIDER (this example builds its fallback from NEXO_MODEL + NEXO_PROVIDER)" unless ENV["NEXO_PROVIDER"]

# Resolve the fallback through the helper's provider settings (base URL, key).
class Probe < Nexo::Agent
  Examples.model(self)
end
FALLBACK, = RubyLLM.models.resolve(ENV.fetch("NEXO_MODEL"), provider: ENV.fetch("NEXO_PROVIDER").downcase, assume_model_exists: true)

RubyLLM.configure do |config|
  config.openai_api_base = "http://127.0.0.1:9/v1" # nothing listens here
  config.openai_api_key = "unused"
end

class Resilient < Nexo::Agent
  model "gpt-4o-mini" # the primary: unreachable in this example
  provider :openai
  assume_model_exists true

  # Everything in this block is ruby_llm's `RubyLLM::Agent` DSL. What Nexo owns —
  # model, instructions, tools, mcp, skills — is declared outside it, and refused
  # inside it.
  llm do
    fallbacks FALLBACK
    temperature 0.2
    # Cut any single tool result past a quarter of the context window. A model
    # outside ruby_llm's registry has no known window, so say what it is.
    context_budget per_result: 0.25, window: 32_000
  end

  instructions "Answer in one sentence."
end

if __FILE__ == $PROGRAM_NAME
  abort "set NEXO_LIVE=1 to run this live example" unless ENV["NEXO_LIVE"]

  response = Resilient.new.prompt("Why would an application declare a fallback model?") do |type, payload|
    puts "fallback:  #{payload.from.id} -> #{payload.to.id} (#{payload.error.class})" if type == :fallback
  end
  puts "answer:    #{response.content}"

  chat = Resilient.new.chat
  puts "on the chat: temperature=#{chat.temperature.inspect} budget=#{chat.context_budget.inspect}"
end
