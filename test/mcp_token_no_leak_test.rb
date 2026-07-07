# frozen_string_literal: true

require "test_helper"

# Spec 18 — no-leak guarantee (passive). A bearer token injected by Nexo::MCP.build
# lives only in the in-memory header Hash handed to ruby_llm-mcp; it must never reach
# the event path. This drives a Workflow whose (stubbed) MCP tool is exercised via the
# Spec 8 run_agent glue and asserts the bearer value appears NOWHERE in run.events.
#
# The reducer (Workflow#reduce_tool_call/#reduce_tool_result) carries only tool
# name/args and the tool's return value — never connection config or headers — so the
# guarantee holds without any active redaction guard.
class McpTokenNoLeakTest < Minitest::Test
  SECRET = "SUPER-SECRET-BEARER-abc123"

  def setup = Nexo::RunStore::Memory.reset!

  # Records the config ruby_llm-mcp would receive, and exposes the wrapped MCP tool
  # so the spy agent can exercise it through the real Nexo::MCP::GatedTool.
  class FakeClientFactory
    attr_reader :config

    def client(name:, transport_type:, config:)
      @config = config
      FakeClient.new
    end

    # A minimal ruby_llm-mcp-shaped client exposing one read tool.
    class FakeClient
      def tools = [FakeTool.new]

      def stop = nil
    end

    # A ruby_llm-mcp tool whose call returns a normal read result — no token.
    class FakeTool
      def name = "search_threads"

      def description = "search Gmail threads"

      def params_schema = {}

      def call(_args = {}) = "3 threads matched"
    end
  end

  # A spy agent that BUILDS a real MCP client config carrying the secret token (so the
  # token genuinely flows through Nexo::MCP.build), gates the tool through the unchanged
  # Spec 6 gate, then yields the loop events the real Loops::RubyLLM would.
  class SpyAgent
    def initialize(sandbox: nil, **)
      @sandbox = sandbox
    end

    def prompt(_text, max_turns: 25)
      client = Nexo::MCP.stub_client_factory(FakeClientFactory.new) do
        Nexo::MCP.build(name: :gmail, transport: :http, url: "https://x", token: -> { SECRET })
      end
      perms = Nexo::Permissions.new(mode: :read_only, mcp_allow: %w[search_threads])
      tool = Nexo::MCP::GatedTool.new(tool: client.tools.first, permissions: perms)
      args = {"query" => "in:inbox"}
      result = tool.call(args)

      if block_given?
        yield(:tool_call, {name: tool.name, args: args})
        yield(:tool_result, result)
        yield(:done, Struct.new(:content).new("digest ready"))
      end
      Struct.new(:content).new("digest ready")
    end

    def close = nil
  end

  class DrivenWorkflow < Nexo::Workflow
    agent SpyAgent

    def call(_payload)
      resp = run_agent("Triage the inbox")
      {content: resp.content}
    end
  end

  def test_token_never_appears_in_events
    run = DrivenWorkflow.run

    assert_equal "done", run.status

    # The tool WAS exercised (proving the path is live), but the bearer is absent.
    types = run.events.map { |e| e["type"] || e[:type] }
    assert_includes types, "agent_tool_call"
    assert_includes types, "agent_tool_result"

    serialized = run.events.join
    refute_includes serialized, SECRET, "the bearer token must never surface in run.events"
    refute_includes serialized, "Authorization", "no connection headers reach the event log"
  end
end
