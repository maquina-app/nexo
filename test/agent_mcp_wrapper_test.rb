# frozen_string_literal: true

require "test_helper"

# Agent#wrap_mcp_tool is the seam for decorating every MCP tool an agent is given —
# capping an oversized reply, recording timings, redacting a field. Without it the
# only way in was overriding the private #apply_mcp.
class AgentMcpWrapperTest < Minitest::Test
  class FakeMcpTool
    def name = "get_email"

    def description = "Get one email"

    def params_schema = {"type" => "object"}

    def call(_args = {}) = "x" * 100
  end

  class FakeClient
    def tools = [FakeMcpTool.new]

    def close = nil
  end

  # Truncates whatever the wrapped tool returns, delegating everything else.
  class CappingTool
    def initialize(tool:, max_chars:)
      @tool = tool
      @max_chars = max_chars
    end

    def call(args = {}) = @tool.call(args).to_s[0, @max_chars]

    def name = @tool.name

    def respond_to_missing?(m, include_private = false) = @tool.respond_to?(m, include_private) || super

    def method_missing(m, *args, **kwargs, &blk)
      @tool.respond_to?(m) ? @tool.public_send(m, *args, **kwargs, &blk) : super
    end
  end

  class PlainAgent < Nexo::Agent
    model "test-model"
    mcp :fake, transport: :stdio, command: "fake"
  end

  class WrappingAgent < Nexo::Agent
    model "test-model"
    mcp :fake, transport: :stdio, command: "fake"

    def wrap_mcp_tool(tool) = CappingTool.new(tool: tool, max_chars: 10)
  end

  def build(klass)
    agent = klass.new
    agent.instance_variable_set(:@mcp_clients, [FakeClient.new])
    agent
  end

  def attached(agent)
    chat = Minitest::Mock.new
    captured = nil
    chat.expect(:with_tools, nil) { |*tools| captured = tools }
    agent.send(:apply_mcp, chat)
    captured
  end

  def test_tools_are_gated_by_default
    tool = attached(build(PlainAgent)).first

    assert_kind_of Nexo::MCP::GatedTool, tool
  end

  def test_wrap_mcp_tool_decorates_every_attached_tool
    tool = attached(build(WrappingAgent)).first

    assert_kind_of CappingTool, tool
    assert_equal "get_email", tool.name
  end

  def test_the_wrapper_sees_an_already_gated_tool
    tool = attached(build(WrappingAgent)).first

    assert_kind_of Nexo::MCP::GatedTool, tool.instance_variable_get(:@tool)
  end

  def test_the_wrapper_can_change_the_result
    tool = attached(build(WrappingAgent)).first

    assert_equal 10, tool.call({}).length
  end

  def test_delegation_still_reaches_the_underlying_tool
    tool = attached(build(WrappingAgent)).first

    assert_equal({"type" => "object"}, tool.params_schema)
  end
end
