# frozen_string_literal: true

require "test_helper"

# The boot/deploy reconciliation sweep (Spec 7 R6) against the Memory store.
# reconcile_interrupted! rewrites only "running" -> "interrupted" and leaves
# terminal states untouched.
class WorkflowReconcileTest < Minitest::Test
  def setup
    Nexo::RunStore::Memory.reset!
    @store = Nexo::RunStore::Memory.new
  end

  def test_rewrites_running_runs_to_interrupted
    run = @store.create(workflow_class: "Demo", payload: {})
    run.update!(status: "running")

    count = Nexo::Workflow.reconcile_interrupted!

    assert_equal 1, count
    assert_equal "interrupted", @store.find(run.id).status
  end

  def test_leaves_done_and_failed_runs_untouched
    done = @store.create(workflow_class: "Demo", payload: {})
    done.update!(status: "done")
    failed = @store.create(workflow_class: "Demo", payload: {})
    failed.update!(status: "failed")

    Nexo::Workflow.reconcile_interrupted!

    assert_equal "done", @store.find(done.id).status
    assert_equal "failed", @store.find(failed.id).status
  end

  # 0.16: a host on the Disk store — a CLI killed mid-run — is swept too, and the
  # interrupted run can then be retried with its checkpoints.
  def test_sweeps_the_disk_store_and_the_run_can_then_be_retried
    require "tmpdir"
    Dir.mktmpdir do |dir|
      Nexo.config.run_store = Nexo::RunStore::Disk.new(dir: dir)
      workflow = Class.new(Nexo::Workflow) do
        def call(_payload) = {read: checkpoint("read") { "fresh" }}
      end
      Object.const_set(:ReconcileDiskFlow, workflow)
      run = Nexo::RunStore.default.create(workflow_class: "ReconcileDiskFlow", payload: {})
      run.update!(status: "running", state: {"read" => "kept"}) # what a killed process leaves behind

      assert_equal 1, Nexo::Workflow.reconcile_interrupted!
      assert_equal "interrupted", Nexo::RunStore::Disk.new(dir: dir).find(run.id).status

      retried = ReconcileDiskFlow.retry(run.id)
      assert_equal "done", retried.status
      assert_equal({"read" => "kept"}, retried.result)
    end
  ensure
    Object.send(:remove_const, :ReconcileDiskFlow) if Object.const_defined?(:ReconcileDiskFlow)
    Nexo.reset_config!
  end

  def test_returns_zero_when_nothing_is_running
    @store.create(workflow_class: "Demo", payload: {}).update!(status: "pending")

    assert_equal 0, Nexo::Workflow.reconcile_interrupted!
  end
end
