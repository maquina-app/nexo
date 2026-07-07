# frozen_string_literal: true

require "test_helper"

# Spec 16 — run_agent bridges an agent's :approve gate to a durable suspend:
# first pass suspends recording the pending call, resume threads the decision so
# the gate allows (→ done) or denies (→ done, gated effect skipped). Offline,
# Memory store, in-process resume, and a REAL recording spy agent (not
# Minitest::Mock) that gates through a genuine :approve Permissions — the point is
# the bridge, not live tool-calling.
class WorkflowApprovalTest < Minitest::Test
  def setup = Nexo::RunStore::Memory.reset!

  # A real agent stand-in. It builds a genuine :approve Permissions carrying the
  # per-run decision (exactly as Nexo::Agent does), then models a tool calling the
  # gate: no decision ⇒ authorize! raises ApprovalRequired and it propagates out of
  # #prompt (the spy does NOT rescue it — Group 0 Branch A); approved ⇒ the write
  # "succeeds"; denied ⇒ the tool rescues Denied into {error:} and the model adapts
  # to a normal completion (the run finishes, the gated effect skipped).
  class SpyAgent
    attr_reader :closed

    def initialize(sandbox: nil, decision: nil, **)
      @permissions = Nexo::Permissions.new(mode: :approve, decision: decision)
      @closed = false
    end

    def prompt(_text, max_turns: 25)
      @permissions.authorize!(:write, "/protected/x")
      Struct.new(:content).new("wrote /protected/x")
    rescue Nexo::Permissions::Denied => e
      Struct.new(:content).new("could not write: #{e.message}")
    end

    def close = (@closed = true)
  end

  class NeedsApproval < Nexo::Workflow
    agent SpyAgent
    def call(_payload)
      resp = run_agent("do the sensitive thing")
      {content: resp.content}
    end
  end

  def test_first_pass_suspends_awaiting_approval
    run = NeedsApproval.run
    assert_equal "suspended", run.status
    assert_match(/approval/, run.state["__suspend__"]["reason"])
  end

  def test_first_pass_records_the_pending_call_in_state
    run = NeedsApproval.run
    approval = run.state["__approval__"]
    assert_equal "write", approval["capability"]
    assert_equal "/protected/x", approval["tool"]
  end

  def test_first_pass_suspend_carries_the_tool_as_resume_key
    run = NeedsApproval.run
    assert_equal "/protected/x", run.state["__suspend__"]["resume_key"]
  end

  def test_resume_with_approval_completes
    run = NeedsApproval.run
    resumed = NeedsApproval.resume(run.id, approved: true)
    assert_equal "done", resumed.status
    assert_equal "wrote /protected/x", resumed.result["content"]
  end

  def test_resume_with_denial_completes_without_the_gated_effect
    run = NeedsApproval.run
    resumed = NeedsApproval.resume(run.id, approved: false)
    # A denial is recoverable: the run finishes "done" (NOT "failed"), the model
    # having adapted to the tool's {error:}, and the gated write never happened.
    assert_equal "done", resumed.status
    assert_match(/could not write/, resumed.result["content"])
  end

  def test_agent_is_closed_even_when_it_suspends
    # The ensure-close must still run when run_agent rescues ApprovalRequired and
    # suspends. Prove it by capturing the agent instance the workflow builds.
    built = []
    spy_class = Class.new(SpyAgent) do
      define_method(:initialize) do |sandbox: nil, decision: nil, **|
        super(sandbox: sandbox, decision: decision)
        built << self
      end
    end
    workflow = Class.new(Nexo::Workflow) do
      agent spy_class
      def call(_p) = {content: run_agent("go").content}
    end
    Object.const_set(:ClosesOnSuspend, workflow)
    run = workflow.run
    assert_equal "suspended", run.status
    assert_equal 1, built.size
    assert built.first.closed, "expected the agent to be closed after a suspend"
  ensure
    Object.send(:remove_const, :ClosesOnSuspend) if defined?(ClosesOnSuspend)
  end
end
