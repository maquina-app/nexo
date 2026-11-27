# frozen_string_literal: true

# Shared by the live examples: which model an example agent runs on.
#
#   NEXO_MODEL     the model id (required)
#   NEXO_PROVIDER  optional. Set it for a model ruby_llm's registry does not
#                  list — a local Ollama tag, a self-hosted build:
#
#     NEXO_MODEL=gemma3:12b NEXO_PROVIDER=ollama ruby -Ilib examples/chat_session.rb
#
#   OLLAMA_API_BASE and API_KEY point the `ollama` provider at any local
#   OpenAI-compatible server (default http://127.0.0.1:11434/v1, no key).
#
# With a provider the registry lookup is skipped (`assume_model_exists`), which
# is what an unlisted model needs; without one, `NEXO_MODEL` must be a model the
# registry knows (`gpt-4o-mini`, `claude-sonnet-5-5`…) and its API key must be set.
module Examples
  # Declares the model on `agent_class` from the environment.
  def self.model(agent_class, default: nil)
    agent_class.model(default ? ENV.fetch("NEXO_MODEL", default) : ENV.fetch("NEXO_MODEL"))
    provider = ENV["NEXO_PROVIDER"]&.downcase or return

    agent_class.provider provider.to_sym
    agent_class.assume_model_exists true
    return unless provider == "ollama"

    RubyLLM.configure do |config|
      config.ollama_api_base ||= ENV.fetch("OLLAMA_API_BASE", "http://127.0.0.1:11434/v1")
      # Ollama itself needs no key; a local OpenAI-compatible server may.
      config.ollama_api_key ||= ENV["API_KEY"] if ENV["API_KEY"]
    end
  end
end
