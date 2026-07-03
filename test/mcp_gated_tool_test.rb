# frozen_string_literal: true

require "test_helper"

# A real Ruby object standing in for a ruby_llm-mcp tool at the external boundary
# (the WebMock analogue). NOT a mock — it just quacks like a tool and records calls.
class FakeMcpTool
  attr_reader :name, :calls

  def initialize(name)
    @name = name
    @calls = []
  end

  def description = "fake #{@name}"

  def call(args = {})
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

  def test_missing_gem_raises_missing_dependency
    # When ruby_llm-mcp is not installed, .load! must surface a Nexo error, not a
    # bare LoadError. Skipped where the gem IS present (it is a dev dep here). The
    # guard checks installability, not `defined?` — .load! requires lazily, so the
    # constant is absent until first use even when the gem is installed.
    skip "runs only where ruby_llm-mcp is absent" if Gem::Specification.find_all_by_name("ruby_llm-mcp").any?
    assert_raises(Nexo::MissingDependencyError) { Nexo::MCP.load! }
  end
end
