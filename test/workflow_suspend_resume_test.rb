# frozen_string_literal: true

require "test_helper"

# Spec 13 — `suspend!` marks a run "suspended" (NOT failed) without raising out of
# Workflow.run, and Workflow.resume re-enters #call from the top, skipping completed
# checkpoints, until it finishes. Offline (Memory store, in-process resume).
class WorkflowSuspendResumeTest < Minitest::Test
  def setup = Nexo::RunStore::Memory.reset!

  class Approval < Nexo::Workflow
    def call(payload)
      fetched = checkpoint(:fetch) { "doc-#{payload[:id]}" }
      suspend!(reason: "needs approval", resume_key: "run-#{payload[:id]}") unless resume_input[:approved]
      checkpoint(:publish) { "published #{fetched}" }
      {done: true}
    end
  end

  def test_suspend_marks_suspended_without_raising
    run = Approval.run(id: 7)
    assert_equal "suspended", run.status
    assert_equal "needs approval", run.state["__suspend__"]["reason"]
    assert_equal "run-7", run.state["__suspend__"]["resume_key"] # Q2: resume_key persisted
    assert_equal "doc-7", run.state["fetch"] # the pre-suspend checkpoint persisted
  end

  def test_resume_skips_completed_checkpoints_and_finishes
    run = Approval.run(id: 7)
    resumed = Approval.resume(run.id, approved: true)
    assert_equal "done", resumed.status
    assert_equal true, resumed.result["done"]
    assert_equal "published doc-7", resumed.state["publish"]
  end

  def test_resume_does_not_rerun_the_completed_checkpoint_block
    # The :fetch checkpoint must NOT re-run on resume — prove it with a real counter.
    counter = Hash.new(0)
    klass = Class.new(Nexo::Workflow) do
      define_method(:counter) { counter }
      def call(_p)
        checkpoint(:fetch) { counter[:fetch] += 1 }
        suspend!(reason: "wait") unless resume_input[:go]
        {ok: true}
      end
    end
    Object.const_set(:CounterApproval, klass)
    run = klass.run
    assert_equal 1, counter[:fetch]
    resumed = klass.resume(run.id, go: true)
    assert_equal "done", resumed.status
    assert_equal 1, counter[:fetch] # checkpoint block ran exactly once across both passes
  ensure
    Object.send(:remove_const, :CounterApproval) if defined?(CounterApproval)
  end

  def test_resume_guards_non_suspended_runs
    klass = Class.new(Nexo::Workflow) do
      def call(_p) = {ok: true}
    end
    Object.const_set(:DoneWorkflow, klass)
    run = klass.run
    assert_equal "done", run.status
    err = assert_raises(Nexo::Error) { klass.resume(run.id) }
    assert_match(/not suspended \(done\)/, err.message)
  ensure
    Object.send(:remove_const, :DoneWorkflow) if defined?(DoneWorkflow)
  end

  def test_reconcile_leaves_suspended_runs_untouched
    run = Approval.run(id: 7)
    assert_equal "suspended", run.status
    Nexo::Workflow.reconcile_interrupted!
    assert_equal "suspended", Nexo::RunStore.default.find(run.id).status
  end
end
