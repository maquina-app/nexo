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

  # :approve must NOT fail open on the MCP axis. An undecided gate suspends
  # (raises ApprovalRequired), an allow-listed tool is pre-approved, an approved
  # decision allows, and a denial Denies — the strict mode is never weaker than
  # :read_only.
  def test_approve_undecided_raises_approval_required
    p = Nexo::Permissions.new(mode: :approve) # no decision, empty mcp_allow
    err = assert_raises(Nexo::ApprovalRequired) { p.authorize_mcp!("send_email", {to: "x"}) }
    assert_equal :mcp, err.capability
    assert_equal "send_email", err.detail
    assert_equal({to: "x"}, err.args)
  end

  def test_approve_preapproves_allowlisted_tool
    p = Nexo::Permissions.new(mode: :approve, mcp_allow: %w[search_threads])
    assert p.authorize_mcp!("search_threads")
  end

  def test_approve_with_decision_allows_and_denies
    allowed = Nexo::Permissions.new(mode: :approve, decision: {approved: true})
    assert allowed.authorize_mcp!("send_email")

    denied = Nexo::Permissions.new(mode: :approve, decision: {approved: false})
    assert_raises(Nexo::Permissions::Denied) { denied.authorize_mcp!("send_email") }
  end
end
