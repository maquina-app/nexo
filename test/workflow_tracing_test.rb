# frozen_string_literal: true

require "test_helper"

# 0.14: a run executes inside ruby_llm's workflow context, so ruby_llm's own
# instrumentation carries the Nexo run id — without changing any outcome.
class WorkflowTracingTest < Minitest::Test
  # Stands in for `RubyLLM.config.instrumenter` and records every event.
  class Recorder
    attr_reader :events

    def initialize = @events = []

    def instrument(name, payload = {})
      @events << [name, payload.dup]
      block_given? ? yield(payload) : nil
    end
  end

  class Traced < Nexo::Workflow
    def call(_payload)
      {value: checkpoint(:extract) { 41 + 1 }}
    end
  end

  class Pausing < Nexo::Workflow
    def call(_payload) = suspend!(reason: "wait")
  end

  class Failing < Nexo::Workflow
    def call(_payload) = raise(ArgumentError, "boom")
  end

  def setup
    Nexo::RunStore::Memory.reset!
    @previous = RubyLLM.config.instrumenter
    @recorder = Recorder.new
    RubyLLM.config.instrumenter = @recorder
  end

  def teardown
    RubyLLM.config.instrumenter = @previous
  end

  def test_a_run_is_a_ruby_llm_workflow_carrying_the_run_id
    run = Traced.run

    name, payload = @recorder.events.find { |event, _| event == "workflow.ruby_llm" }
    assert_equal "done", run.status
    assert_equal({"value" => 42}, run.result)
    assert_equal "workflow.ruby_llm", name
    assert_equal run.id, payload[:workflow_id]
    assert_equal "WorkflowTracingTest::Traced", payload[:workflow_name]
  end

  def test_a_checkpoint_is_a_step_of_that_workflow
    run = Traced.run

    _name, payload = @recorder.events.find { |event, _| event == "workflow_step.ruby_llm" }
    assert_equal "extract", payload[:workflow_step_name]
    assert_equal run.id, payload[:workflow_id]
  end

  def test_a_suspend_still_returns_a_suspended_run
    run = Pausing.run

    assert_equal "suspended", run.status
    assert_equal "wait", run.state["__suspend__"]["reason"]
  end

  def test_a_failure_still_fails_the_run_and_re_raises
    error = assert_raises(ArgumentError) { Failing.run }

    assert_equal "boom", error.message
    assert_equal ["failed"], Nexo::RunStore::Memory.runs.values.map(&:status)
  end

  def test_an_anonymous_workflow_class_still_runs
    run = Class.new(Nexo::Workflow) { def call(_payload) = {ok: true} }.run

    assert_equal "done", run.status
  end
end
