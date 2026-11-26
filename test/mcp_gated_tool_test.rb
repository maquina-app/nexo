# frozen_string_literal: true

require "test_helper"

# A real Ruby object standing in for an MCP tool at the external boundary (the
# WebMock analogue). NOT a mock — it just quacks like a tool and records calls. It
# takes KEYWORDS, as ruby_llm's chat loop calls every tool (`tool.call(**arguments)`).
class FakeMcpTool
  attr_reader :name, :calls

  def initialize(name)
    @name = name
    @calls = []
  end

  def description = "fake #{@name}"

  def call(**args)
    @calls << args
    {ok: true, tool: @name, echo: args}
  end
end

class McpGatedToolTest < Minitest::Test
  def test_allowed_call_delegates_to_wrapped_tool
    tool = FakeMcpTool.new("search_threads")
    perms = Nexo::Permissions.new(mode: :read_only, mcp_allow: %w[search_threads])
    gated = Nexo::MCP::GatedTool.new(tool: tool, permissions: perms)

    result = gated.call({q: "invoice"})
    assert_equal({ok: true, tool: "search_threads", echo: {q: "invoice"}}, result)
    assert_equal [{q: "invoice"}], tool.calls
  end

  def test_denied_call_returns_error_and_does_not_delegate
    tool = FakeMcpTool.new("send_email")
    perms = Nexo::Permissions.new(mode: :read_only, mcp_allow: %w[search_threads])
    gated = Nexo::MCP::GatedTool.new(tool: tool, permissions: perms)

    result = gated.call({to: "x@y.z"})
    assert result[:error] # recoverable, not raised
    assert_empty tool.calls # the real tool was never reached
  end

  def test_delegates_name_and_description
    tool = FakeMcpTool.new("get_thread")
    gated = Nexo::MCP::GatedTool.new(tool: tool, permissions: Nexo::Permissions.new(mode: :auto))
    assert_equal "get_thread", gated.name
    assert_equal "fake get_thread", gated.description
  end

  # #execute (the UNGATED tool body) must route back through the gate, not forward
  # to the wrapped tool, so a caller invoking #execute directly can't bypass
  # authorization.
  def test_execute_is_gated_not_forwarded
    tool = FakeMcpTool.new("send_email")
    perms = Nexo::Permissions.new(mode: :read_only, mcp_allow: %w[search_threads])
    gated = Nexo::MCP::GatedTool.new(tool: tool, permissions: perms)

    result = gated.execute(to: "x@y.z")
    assert result[:error] # denied, exactly like #call — not forwarded ungated
    assert_empty tool.calls
  end

  def test_execute_on_allowed_tool_delegates_like_call
    tool = FakeMcpTool.new("search_threads")
    perms = Nexo::Permissions.new(mode: :read_only, mcp_allow: %w[search_threads])
    gated = Nexo::MCP::GatedTool.new(tool: tool, permissions: perms)

    result = gated.execute(q: "invoice")
    assert_equal({ok: true, tool: "search_threads", echo: {q: "invoice"}}, result)
    assert_equal [{q: "invoice"}], tool.calls
  end
end
