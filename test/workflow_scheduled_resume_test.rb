# frozen_string_literal: true

require "test_helper"

# ActiveJob is a soft, Rails-side dependency: the offline core suite normally
# runs without it. These Spec 21 scheduling tests need it, so they load it (and
# the Zeitwerk-ignored WorkflowJob) in-process — active_job pulls in neither
# ActiveRecord nor Rails::Engine, so RunStore.default stays the Memory store and
# the no-Rails guarantees hold. Jobs are inspected via the :test adapter's
# enqueued_jobs, never performed.
require "active_job"
require "nexo/workflow_job"

# Spec 21 — wait:/wait_until: forward to ActiveJob's own .set(...), so a
# workflow can schedule its own future enqueue/resume without Nexo building a
# scheduler. Uses the ActiveJob :test adapter so jobs are inspectable via
# ActiveJob::Base.queue_adapter.enqueued_jobs, not actually executed.
class WorkflowScheduledResumeTest < Minitest::Test
  class ScheduledDemo < Nexo::Workflow
    def call(payload) = {echoed: payload}
  end

  def setup
    Nexo::RunStore::Memory.reset!
    ActiveJob::Base.queue_adapter = :test
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  end

  def test_run_later_with_wait_schedules_the_job
    ScheduledDemo.run_later({x: 1}, wait: 300)
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    refute_nil job[:at], "expected the job to carry a scheduled time"
  end

  def test_run_later_with_no_scheduling_options_enqueues_immediately
    ScheduledDemo.run_later({x: 1})
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    assert_nil job[:at], "no wait/wait_until given — must enqueue immediately, unchanged from pre-Spec-21 behavior"
  end

  def test_run_later_raises_when_both_wait_and_wait_until_given
    err = assert_raises(ArgumentError) do
      ScheduledDemo.run_later({x: 1}, wait: 60, wait_until: Time.now + 3600)
    end
    assert_match(/wait.*wait_until|wait_until.*wait/, err.message)
  end

  def test_resume_later_with_wait_until_schedules_the_resume_job
    run = ScheduledDemo.run(x: 1) # not suspended, but resume_later only needs a run to exist for this test
    ScheduledDemo.resume_later(run.id, {approved: true}, wait_until: Time.now + 3600)
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    refute_nil job[:at]
  end

  # Documents the pre-existing ambiguity (queue: already had it): a payload
  # that legitimately needs a key literally named "wait" must be passed as an
  # explicit positional Hash, since bare keywords can't distinguish "this is
  # payload data" from "this is the scheduling option."
  def test_a_payload_key_literally_named_wait_requires_the_positional_hash_form
    # Bare-keyword form: `wait:` here is consumed as the scheduling option,
    # NOT stored as payload data.
    ScheduledDemo.run_later(wait: 60)
    job = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    refute_nil job[:at]

    run = Nexo::RunStore.default.find(job[:args].first)
    assert_equal({}, run.payload) # "wait" did not survive into the payload

    # Positional-Hash form: explicit, unambiguous — this is how to send
    # payload data that happens to be named "wait".
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ScheduledDemo.run_later({wait: "some domain value"})
    job2 = ActiveJob::Base.queue_adapter.enqueued_jobs.last
    assert_nil job2[:at] # no scheduling option was given this time
    run2 = Nexo::RunStore.default.find(job2[:args].first)
    assert_equal({"wait" => "some domain value"}, run2.payload)
  end
end
