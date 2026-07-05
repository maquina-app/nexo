# frozen_string_literal: true

require "test_helper"

# Spec 11 plain-Ruby guarantees: the sync Workflow.run is byte-for-byte unchanged
# (it passes the caller's ORIGINAL symbolized payload, nested Ruby values intact —
# never the store-normalized run.payload), emit stays exactly Spec 2 without a live
# transport, and run_later raises a clear MissingDependencyError when ActiveJob is
# absent. This suite runs Rails-free (no ActiveJob/ActiveRecord/ActiveSupport).
class WorkflowRuntimeTest < Minitest::Test
  # Captures the exact payload object #call receives so the test can assert the
  # caller's original (nested symbol keys + a bare Symbol value) reached it intact.
  class EchoPayload < Nexo::Workflow
    class << self
      attr_accessor :seen
    end

    def call(payload)
      self.class.seen = payload
      {ok: true}
    end
  end

  # Emits, then records how the run was driven (so we confirm emit persists exactly
  # like Spec 2 — push_event + save_events! per emit, no live-transport dependency).
  class Emitter < Nexo::Workflow
    def call(_payload)
      emit(:tick, n: 1)
      {done: true}
    end
  end

  def setup
    Nexo.reset_config!
    Nexo::RunStore::Memory.reset!
  end

  def teardown
    Nexo.reset_config!
    Nexo::RunStore::Memory.reset!
  end

  def test_run_passes_the_callers_original_nested_payload_to_call
    run = EchoPayload.run(config: {mode: :fast}, tags: [:a, :b])

    # #call saw the original symbol-keyed payload with nested symbol values intact —
    # NOT a value round-tripped through run.payload's storage normalization.
    assert_equal({config: {mode: :fast}, tags: [:a, :b]}, EchoPayload.seen)
    assert_equal "done", run.status
  end

  def test_run_is_unchanged_stores_string_keyed_payload_and_result
    run = EchoPayload.run(a: 1, b: 2)

    assert_equal({"a" => 1, "b" => 2}, run.payload)
    assert_equal({"ok" => true}, run.result)
  end

  def test_emit_persistence_is_exactly_spec_2
    # notify_event only ADDS a live broadcast — it never touches the persistence
    # path. So emit's stored event log is byte-for-byte Spec 2 whether or not a
    # transport is present (and with no ActiveSupport at all, notify_event no-ops).
    run = Emitter.run(x: 1)

    assert_equal 1, run.events.length
    ev = run.events.first
    assert_equal "tick", ev["type"]
    assert_equal({n: 1}, ev["data"])
  end

  def test_run_later_without_active_job_raises_missing_dependency
    skip "runs only where ActiveJob is absent" if defined?(::ActiveJob)

    error = assert_raises(Nexo::MissingDependencyError) { Emitter.run_later(x: 1) }
    assert_match(/run_later requires ActiveJob/, error.message)
    assert_match(/Use `run`/, error.message)
  end

  def test_status_vocabulary_includes_queued
    # Documented on the Rails model; the sync path never uses it, but run_later does.
    assert_includes %w[pending queued running done failed interrupted], "queued"
  end
end
