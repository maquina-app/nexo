# frozen_string_literal: true

require "test_helper"

# Spec 16 — the :approve permission mode. With no decision the gate raises
# Nexo::ApprovalRequired (→ a durable suspend); with {approved: true} it allows;
# with {approved: false} it raises Denied. The Spec 14 ask_when predicate scopes
# which actions need a decision at all (unchanged semantics).
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

  def test_approve_with_granted_decision_allows
    p = Nexo::Permissions.new(mode: :approve, decision: {approved: true})
    assert p.authorize!(:write, "/protected/x")
  end

  def test_approve_with_denied_decision_denies
    p = Nexo::Permissions.new(mode: :approve, decision: {approved: false})
    assert_raises(Nexo::Permissions::Denied) { p.authorize!(:write, "/protected/x") }
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

  def test_approve_when_alias_maps_onto_the_same_predicate
    p = Nexo::Permissions.new(
      mode: :approve,
      approve_when: ->(cap, _detail) { cap == :write }
    )
    assert p.authorize!(:shell, "ls") # not :write ⇒ scoped-out ⇒ auto-allow
    assert_raises(Nexo::ApprovalRequired) { p.authorize!(:write, "/x") }
  end

  def test_with_decision_returns_a_copy_leaving_the_receiver_undecided
    base = Nexo::Permissions.new(mode: :approve)
    approved = base.with_decision({approved: true})

    assert approved.authorize!(:write, "/x") # the copy is decided
    assert_nil base.decision # the original is untouched
    assert_raises(Nexo::ApprovalRequired) { base.authorize!(:write, "/x") }
  end

  def test_approval_required_is_distinct_from_denied
    refute_operator Nexo::ApprovalRequired, :<=, Nexo::Permissions::Denied
    refute_operator Nexo::Permissions::Denied, :<=, Nexo::ApprovalRequired
    assert_operator Nexo::ApprovalRequired, :<, StandardError
  end

  # --- 0.14: per-call decisions ----------------------------------------------

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

  def test_per_call_decisions_win_over_the_global_decision
    perms = Nexo::Permissions.new(mode: :approve, decision: {approved: true}, decisions: {})

    assert_raises(Nexo::ApprovalRequired) { perms.authorize!(:write, "a.txt") }
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
end
