# frozen_string_literal: true

require "test_helper"

class McpPermissionsTest < Minitest::Test
  def test_read_only_allows_listed_tool
    p = Nexo::Permissions.new(mode: :read_only, mcp_allow: %w[search_threads])
    assert p.authorize_mcp!("search_threads")
  end

  def test_read_only_denies_unlisted_tool
    p = Nexo::Permissions.new(mode: :read_only, mcp_allow: %w[search_threads])
    assert_raises(Nexo::Permissions::Denied) { p.authorize_mcp!("send_email") }
  end

  def test_read_only_empty_allowlist_fails_closed
    p = Nexo::Permissions.new(mode: :read_only) # mcp_allow defaults to []
    assert_raises(Nexo::Permissions::Denied) { p.authorize_mcp!("anything") }
  end

  def test_auto_allows_everything
    p = Nexo::Permissions.new(mode: :auto)
    assert p.authorize_mcp!("send_email")
  end

  def test_ask_receives_tool_and_args_and_can_deny
    seen = nil
    gate = ->(cap, detail) {
      seen = [cap, detail]
      false
    } # a real proc, not a mock
    p = Nexo::Permissions.new(mode: :ask, on_ask: gate)
    assert_raises(Nexo::Permissions::Denied) { p.authorize_mcp!("send_email", {to: "x@y.z"}) }
    assert_equal :mcp, seen.first
    assert_equal({tool: "send_email", args: {to: "x@y.z"}}, seen.last)
  end
end
