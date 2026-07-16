# frozen_string_literal: true

require "test_helper"

# ActiveJob loaded in-process for the :test adapter (see
# workflow_scheduled_resume_test.rb) — keeps the Memory store, no Rails.
require "active_job"
require "nexo/workflow_job"

# Spec 21 integration: checkpoint_all + suspend! + a scheduled resume_later,
# combining both features from this spec in one workflow, end to end.
class WorkflowScheduledCheckpointIntegrationTest < Minitest::Test
  class FetchThenApprove < Nexo::Workflow
    def call(payload)
      fetched = checkpoint_all(
        left: -> { "left-#{payload[:id]}" },
        right: -> { "right-#{payload[:id]}" }
      )
      suspend!(reason: "needs approval") unless resume_input[:approved]
      {combined: "#{fetched[:left]}+#{fetched[:right]}"}
    end
  end

  def setup
    Nexo::RunStore::Memory.reset!
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  def test_checkpoint_all_then_scheduled_suspend_and_resume
    run = FetchThenApprove.run(id: 9)
    assert_equal "suspended", run.status
    assert_equal "left-9", run.state["left"]
    assert_equal "right-9", run.state["right"]

    FetchThenApprove.resume_later(run.id, {approved: true}, wait: 60)
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    refute_nil job[:at]

    # Simulate the scheduled job firing (the :test adapter doesn't advance
    # time on its own) — perform it directly, mirroring how
    # workflow_suspend_resume_test.rb exercises resume in-process.
    Nexo::Workflow.resume(run.id, approved: true)

    reloaded = Nexo::RunStore.default.find(run.id)
    assert_equal "done", reloaded.status
    assert_equal "left-9+right-9", reloaded.result["combined"]
  end
end
