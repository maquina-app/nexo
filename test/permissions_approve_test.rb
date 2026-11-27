# frozen_string_literal: true

require "test_helper"

# The :approve permission mode, at the gate. A call with no recorded decision
# raises Nexo::ApprovalRequired; one approved in `decisions` is allowed; one
# declined there raises Denied. `ask_when` scopes which actions need a decision
# at all. Through a chat the call pauses before it reaches the gate — see
# test/approval_pause_test.rb.
class PermissionsApproveTest < Minitest::Test
  def test_approve_mode_is_a_valid_mode
    assert_includes Nexo::Permissions::MODES, :approve
  end

  def test_approve_with_no_decision_raises_approval_required
    p = Nexo::Permissions.new(mode: :approve)
    err = assert_raises(Nexo::ApprovalRequired) { p.authorize!(:write, "/protected/x") }
    assert_equal :write, err.capability
    assert_equal "/protected/x", err.detail
  end

  def test_ask_when_scopes_out_auto_allows_without_a_decision
    # Only writes under /protected need approval; everything else auto-allows even
    # with no decision present (never raising ApprovalRequired).
    p = Nexo::Permissions.new(
      mode: :approve,
      ask_when: ->(cap, detail) { cap == :write && detail.to_s.start_with?("/protected") }
    )
    assert p.authorize!(:write, "/public/x") # scoped-out ⇒ auto-allow, no decision
    assert_raises(Nexo::ApprovalRequired) { p.authorize!(:write, "/protected/x") } # in scope ⇒ suspend
  end

  def test_approval_required_is_distinct_from_denied
    refute_operator Nexo::ApprovalRequired, :<=, Nexo::Permissions::Denied
    refute_operator Nexo::Permissions::Denied, :<=, Nexo::ApprovalRequired
    assert_operator Nexo::ApprovalRequired, :<, StandardError
  end

  # --- per-call decisions ------------------------------------------------------

  def approving(decisions) = Nexo::Permissions.new(mode: :approve, decisions: decisions)

  def test_a_decided_call_runs_and_any_other_still_asks
    perms = approving("write:a.txt" => true)

    assert perms.authorize!(:write, "a.txt")
    assert_raises(Nexo::ApprovalRequired) { perms.authorize!(:write, "b.txt") }
    assert_raises(Nexo::ApprovalRequired) { perms.authorize!(:shell, "a.txt") }
  end

  def test_a_declined_call_is_denied
    error = assert_raises(Nexo::Permissions::Denied) { approving("write:a.txt" => false).authorize!(:write, "a.txt") }

    assert_match(/not approved/, error.message)
  end

  def test_an_empty_decision_map_asks_about_everything
    assert_raises(Nexo::ApprovalRequired) { approving({}).authorize!(:write, "a.txt") }
  end

  def test_mcp_calls_are_keyed_by_name_and_arguments
    key = Nexo::Permissions.approval_key(:mcp, "send_email", {to: "a@example.com"})
    perms = approving(key => true)

    assert perms.authorize_mcp!("send_email", {"to" => "a@example.com"}), "string and symbol keys are one call"
    assert_raises(Nexo::ApprovalRequired) { perms.authorize_mcp!("send_email", {to: "b@example.com"}) }
    assert_raises(Nexo::ApprovalRequired) { perms.authorize_mcp!("delete_email", {to: "a@example.com"}) }
  end

  def test_the_key_ignores_argument_order_and_matches_the_signal
    one = Nexo::Permissions.approval_key(:mcp, "t", {a: 1, b: {c: 2, d: 3}})
    two = Nexo::Permissions.approval_key("mcp", "t", {"b" => {"d" => 3, "c" => 2}, "a" => 1})

    assert_equal one, two
    assert_equal one, Nexo::ApprovalRequired.new(:mcp, "t", {a: 1, b: {c: 2, d: 3}}).key
    assert_equal "write:a.txt", Nexo::Permissions.approval_key(:write, "a.txt")
  end

  def test_with_decisions_leaves_the_shared_gate_untouched
    shared = Nexo::Permissions.new(mode: :approve)
    copy = shared.with_decisions("write:a.txt" => true)

    assert copy.authorize!(:write, "a.txt")
    assert_nil shared.decisions
    assert_raises(Nexo::ApprovalRequired) { shared.authorize!(:write, "a.txt") }
  end

  # --- what Approvable asks before a call runs ---------------------------------

  def test_only_approve_mode_needs_approval
    %i[auto read_only ask].each do |mode|
      refute Nexo::Permissions.new(mode: mode).needs_approval?(:write, "a.txt"), mode.to_s
    end
    assert Nexo::Permissions.new(mode: :approve).needs_approval?(:write, "a.txt")
  end

  def test_an_allowed_capability_needs_no_approval
    perms = Nexo::Permissions.new(mode: :approve, allow: %i[read glob])

    refute perms.needs_approval?(:read, "a.txt")
    assert perms.needs_approval?(:shell, "ls")
  end

  def test_ask_when_decides_which_calls_need_approval
    perms = Nexo::Permissions.new(mode: :approve, ask_when: ->(cap, detail) { cap == :write && detail.start_with?("/etc") })

    assert perms.needs_approval?(:write, "/etc/hosts")
    refute perms.needs_approval?(:write, "notes.md")
  end

  def test_an_mcp_tool_needs_approval_unless_it_is_in_mcp_allow
    perms = Nexo::Permissions.new(mode: :approve, mcp_allow: %w[search])

    refute perms.needs_approval?(:mcp, "search", {q: "x"})
    assert perms.needs_approval?(:mcp, "send_email", {to: "a"})
  end

  def test_decision_for_reads_the_recorded_answer
    perms = approving("write:a.txt" => true, "write:b.txt" => false)

    assert_equal true, perms.decision_for(:write, "a.txt")
    assert_equal false, perms.decision_for(:write, "b.txt")
    assert_nil perms.decision_for(:write, "c.txt")
    assert_nil Nexo::Permissions.new(mode: :approve).decision_for(:write, "a.txt")
  end

  def test_the_removed_options_are_refused
    assert_raises(ArgumentError) { Nexo::Permissions.new(mode: :approve, decision: {approved: true}) }
    assert_raises(ArgumentError) { Nexo::Permissions.new(mode: :approve, approve_when: ->(*) { true }) }
  end
end
