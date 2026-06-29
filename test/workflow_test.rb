# frozen_string_literal: true

require "test_helper"

# Workflow base class against the Memory store — no DB, no model, no model API.
class WorkflowTest < Minitest::Test
  # A trivial workflow: emits one event and returns a hash derived from payload.
  class Summarize < Nexo::Workflow
    def call(payload)
      emit(:started, doc_id: payload[:doc_id])
      {summary: payload[:text].to_s.slice(0, 5)}
    end
  end

  # A workflow whose #call raises, to exercise the failure path. It stashes the
  # run record so the test can inspect it after the exception re-raises (the run
  # is not returned to the caller on failure).
  class Boom < Nexo::Workflow
    class << self
      attr_accessor :last_run
    end

    def initialize(run)
      super
      self.class.last_run = run
    end

    def call(_payload)
      raise "kaboom"
    end
  end

  def test_run_returns_a_done_record_with_the_return_value_as_result
    run = Summarize.run(doc_id: 7, text: "hello world")

    assert_equal "done", run.status
    assert_equal "WorkflowTest::Summarize", run.workflow_class
    assert_match(/\A[0-9a-f-]{36}\z/, run.id)
    # result reads back string-keyed (top-level) in the Memory store too, matching
    # the AR json round-trip — the documented payload/result key contract.
    assert_equal({"summary" => "hello"}, run.result)
  end

  def test_payload_is_stored_string_keyed
    run = Summarize.run(doc_id: 7, text: "hello world")

    assert_equal({"doc_id" => 7, "text" => "hello world"}, run.payload)
  end

  def test_a_raising_call_records_failed_and_reraises
    error = assert_raises(RuntimeError) { Boom.run(doc_id: 1) }

    assert_equal "kaboom", error.message
  end

  def test_failed_run_is_recorded_with_the_error_message
    assert_raises(RuntimeError) { Boom.run }

    run = Boom.last_run
    assert_equal "failed", run.status
    assert_equal "kaboom", run.error
  end

  def test_emit_appends_ordered_events_each_with_type_data_and_at
    run = Summarize.run(doc_id: 7, text: "hello")
    ev = run.events.first

    assert_equal 1, run.events.length
    assert_equal "started", ev["type"]
    assert_equal({doc_id: 7}, ev["data"])
    assert_match(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/, ev["at"])
  end

  def test_base_call_raises_not_implemented_naming_the_subclass
    klass = Class.new(Nexo::Workflow)
    instance = klass.new(Object.new)

    error = assert_raises(NotImplementedError) { instance.call({}) }
    assert_match(/must implement #call/, error.message)
  end
end
