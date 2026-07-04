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

  # Live MCP smoke: connect the real filesystem MCP server over stdio and assert the
  # gate lets an allowed read tool through while a denied write tool returns { error: }.
  # No live model needed — it exercises Nexo::MCP.build + MCP::GatedTool against the
  # real ruby_llm-mcp client. Requires npx (the server is an npm package).
  #
  #   NEXO_LIVE=1 bundle exec rake test TEST=test/live_smoke_test.rb
  def test_live_mcp_filesystem_gate_smoke
    skip "set NEXO_LIVE=1 to run live MCP smoke tests" unless ENV["NEXO_LIVE"] == "1"
    skip "npx not found — install Node to run the MCP filesystem server" unless system("which", "npx", out: File::NULL, err: File::NULL)

    require "tmpdir"

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "note.txt"), "hello from mcp\n")

      client = Nexo::MCP.build(
        name: "fs",
        transport: :stdio,
        command: "npx",
        args: ["-y", "@modelcontextprotocol/server-filesystem", dir]
      )

      tools = client.tools
      read_tool = tools.find { |t| t.name.match?(/read/i) }
      write_tool = tools.find { |t| t.name.match?(/write/i) }
      skip "filesystem server exposed no read/write tools" unless read_tool && write_tool

      # read_tool is allowed; write_tool is not → fails closed under :read_only.
      perms = Nexo::Permissions.new(mode: :read_only, mcp_allow: [read_tool.name])

      allowed = Nexo::MCP::GatedTool.new(tool: read_tool, permissions: perms)
      result = allowed.call({path: File.join(dir, "note.txt")})
      refute(result.is_a?(Hash) && result[:error], "allowed read should not be gated: #{result.inspect}")

      denied = Nexo::MCP::GatedTool.new(tool: write_tool, permissions: perms)
      denied_result = denied.call({path: File.join(dir, "new.txt"), content: "nope"})
      assert denied_result[:error], "denied write should return { error: }"
      refute_path_exists File.join(dir, "new.txt")
    ensure
      client&.stop
    end
  end

  # Live fetch smoke (Spec 9): hit a real allow-listed URL and assert a body came
  # back, then assert an off-list host is refused with { error: } and no request.
  # No live model needed — it exercises Nexo::Tools::Fetch against the real network.
  #
  #   NEXO_LIVE=1 bundle exec rake test TEST=test/live_smoke_test.rb
  def test_live_fetch_smoke
    skip "set NEXO_LIVE=1 to run live fetch smoke tests" unless ENV["NEXO_LIVE"] == "1"

    perms = Nexo::Permissions.new(mode: :read_only, allow: %i[read glob fetch])
    tool = Nexo::Tools::Fetch.new(sandbox: Nexo::Sandboxes::Virtual.new,
      permissions: perms, allow_hosts: %w[example.com])

    allowed = tool.execute(url: "https://example.com/")
    refute allowed[:error], "allow-listed fetch should not be denied: #{allowed.inspect}"
    refute_empty allowed[:body].to_s

    denied = tool.execute(url: "https://icanhazip.com/")
    assert denied[:error], "off-list host should return { error: }"
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
