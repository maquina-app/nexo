# frozen_string_literal: true

require "test_helper"

# Optional, manual, env-gated live smoke. Skipped unless NEXO_LIVE=1, so it is
# never part of the offline core suite. It exercises a real provider (Ollama by
# default) end to end — small local models have weak tool-calling, so this may be
# flaky; that is expected and is why it is not a gating test. Point NEXO_MODEL at
# a stronger model if Gemma's tool-calling proves too weak.
#
#   ollama serve &
#   NEXO_LIVE=1 NEXO_MODEL=gemma3:12b bundle exec rake test TEST=test/live_smoke_test.rb
class LiveSmokeTest < Minitest::Test
  def test_live_code_review_smoke
    skip "set NEXO_LIVE=1 to run live model smoke tests" unless ENV["NEXO_LIVE"] == "1"

    require "tmpdir"

    RubyLLM.configure do |config|
      config.ollama_api_base = ENV.fetch("OLLAMA_API_BASE", "http://localhost:11434/v1")
    end

    model = ENV.fetch("NEXO_MODEL")

    agent_class = Class.new(Nexo::Agent) do
      sandbox :local
      permissions :read_only
      instructions "You are a careful code reviewer. Read files and report issues."
    end

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "hello.rb"), "def hello = 'hi'\n")

      agent = agent_class.new(cwd: dir, model: model)
      # provider/assume_model_exists are needed for an unregistered local tag.
      chat = RubyLLM.chat(model: model, provider: :ollama, assume_model_exists: true)
      chat.with_instructions(agent.instructions)
      chat.with_tools(*agent_tools(agent))

      response = chat.ask("List the Ruby files and summarize the project.")

      refute_empty response.content.to_s
    end
  end

  private

  def agent_tools(agent)
    sandbox = agent.sandbox
    permissions = agent.permissions
    [
      Nexo::Tools::ReadFile.new(sandbox: sandbox, permissions: permissions),
      Nexo::Tools::Glob.new(sandbox: sandbox, permissions: permissions)
    ]
  end
end
