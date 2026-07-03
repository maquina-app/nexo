# frozen_string_literal: true

require "test_helper"

class AgentMcpTest < Minitest::Test
  def test_mcp_macro_accumulates_declarations
    klass = Class.new(Nexo::Agent) do
      model "test-model"
      mcp :gmail, transport: :stdio, command: "npx", args: %w[-y srv-gmail]
      mcp :fs, transport: :stdio, command: "npx", args: %w[-y srv-fs /tmp]
    end
    assert_equal 2, klass.mcp.size
    assert_equal :gmail, klass.mcp.first[:name]
    assert_equal :stdio, klass.mcp.first[:transport]
  end

  def test_mcp_allow_threads_into_agent_permissions
    klass = Class.new(Nexo::Agent) do
      model "test-model"
      permissions :read_only
      mcp_allow %w[search_threads get_thread]
    end
    perms = klass.new.permissions
    assert perms.authorize_mcp!("search_threads")
    assert_raises(Nexo::Permissions::Denied) { perms.authorize_mcp!("send_email") }
  end

  def test_default_agent_has_empty_mcp_list
    klass = Class.new(Nexo::Agent) { model "test-model" }
    assert_empty klass.mcp
  end
end
