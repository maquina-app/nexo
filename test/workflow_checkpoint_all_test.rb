# frozen_string_literal: true

require "test_helper"

# Spec 21 — checkpoint_all runs several independent checkpoints concurrently
# via the existing Nexo.concurrent driver, persisting each as it completes
# (not the batch as a whole) so a resume/retry only re-runs what's still
# missing. Offline (Memory store), mirrors workflow_suspend_resume_test.rb's
# conventions.
class WorkflowCheckpointAllTest < Minitest::Test
  def setup = Nexo::RunStore::Memory.reset!

  def test_runs_pending_steps_concurrently_and_persists_each
    in_flight = 0
    peak = 0
    klass = Class.new(Nexo::Workflow) do
      define_method(:call) do |_payload|
        checkpoint_all(
          a: -> {
            in_flight += 1
            peak = [peak, in_flight].max
            sleep(0.01)
            in_flight -= 1
            "a-val"
          },
          b: -> {
            in_flight += 1
            peak = [peak, in_flight].max
            sleep(0.01)
            in_flight -= 1
            "b-val"
          }
        )
        {ok: true}
      end
    end
    Object.const_set(:ConcurrentCheckpoints, klass)

    run = klass.run
    assert_equal "done", run.status
    assert_equal "a-val", run.state["a"]
    assert_equal "b-val", run.state["b"]
    assert_equal 2, peak, "expected both steps to genuinely overlap"
  ensure
    Object.send(:remove_const, :ConcurrentCheckpoints) if defined?(ConcurrentCheckpoints)
  end

  def test_returns_a_hash_keyed_by_the_original_step_names
    captured = nil
    klass = Class.new(Nexo::Workflow) do
      define_method(:call) do |_payload|
        captured = checkpoint_all(alpha: -> { 1 }, beta: -> { 2 })
        {ok: true}
      end
    end
    Object.const_set(:NamedCheckpoints, klass)

    run = klass.run
    # Spec 21 R2.6: returned Hash carries the ORIGINAL (un-stringified) names…
    assert_equal({alpha: 1, beta: 2}, captured)
    # …while run.state reads back string-keyed, like #checkpoint's storage.
    assert_equal({"alpha" => 1, "beta" => 2}, run.state)
  ensure
    Object.send(:remove_const, :NamedCheckpoints) if defined?(NamedCheckpoints)
  end

  def test_raises_on_a_reserved_state_key
    klass = Class.new(Nexo::Workflow) do
      def call(_payload)
        checkpoint_all(__suspend__: -> { "nope" })
      end
    end
    Object.const_set(:ReservedKeyCheckpoints, klass)

    err = assert_raises(Nexo::Error) { klass.run }
    assert_match(/reserved/, err.message)
  ensure
    Object.send(:remove_const, :ReservedKeyCheckpoints) if defined?(ReservedKeyCheckpoints)
  end

  def test_does_not_touch_concurrency_when_nothing_is_pending
    klass = Class.new(Nexo::Workflow) do
      def call(_payload) = checkpoint_all(a: -> { "first pass" })
    end
    Object.const_set(:NoOpSecondPass, klass)
    run = klass.run

    instance = klass.new(run)
    Nexo.stub(:concurrent, ->(*) { flunk "must not touch concurrency when nothing pending" }) do
      result = instance.checkpoint_all(a: -> { flunk "must not re-run a persisted step" })
      assert_equal "first pass", result[:a]
    end
  ensure
    Object.send(:remove_const, :NoOpSecondPass) if defined?(NoOpSecondPass)
  end

  def test_a_partial_failure_persists_completed_steps_and_a_retry_reruns_only_the_missing_one
    klass = Class.new(Nexo::Workflow) do
      class << self; attr_accessor :calls; end
      self.calls = Hash.new(0)

      def call(_payload)
        checkpoint_all(
          a: -> {
            self.class.calls[:a] += 1
            "a-done"
          },
          b: -> {
            self.class.calls[:b] += 1
            raise "boom" if self.class.calls[:b] == 1
            "b-done"
          }
        )
        {ok: true}
      end
    end
    Object.const_set(:PartialFailureCheckpoints, klass)

    error = assert_raises(RuntimeError) { klass.run }
    assert_equal "boom", error.message

    run = Nexo::RunStore::Memory.runs.values.find { |r| r.workflow_class == klass.name }
    assert_equal "failed", run.status
    assert_equal "a-done", run.state["a"]
    refute run.state.key?("b")

    # Simulate a retry the way a retried ActiveJob would: re-run #call from
    # scratch against the SAME run record (no Nexo-provided retry — this is
    # exactly the mechanism docs/rails.md already documents for run_later).
    klass.execute(run, payload: {})

    assert_equal "done", run.status
    assert_equal "a-done", run.state["a"]
    assert_equal "b-done", run.state["b"]
    assert_equal({a: 1, b: 2}, klass.calls) # a's block did NOT re-run; only b's did
  ensure
    Object.send(:remove_const, :PartialFailureCheckpoints) if defined?(PartialFailureCheckpoints)
  end

  def test_missing_async_raises_missing_dependency_error_only_when_something_is_pending
    klass = Class.new(Nexo::Workflow) do
      def call(_payload) = checkpoint_all(a: -> { "val" })
    end
    Object.const_set(:MissingAsyncCheckpoints, klass)

    # Same override as test/concurrent_test.rb's `c.stub(:require, …)`, applied at
    # the class level because checkpoint_all builds its Concurrent instance
    # internally (there is no instance to reach). Simulates the `async` gem being
    # absent: the lazy require inside Nexo::Concurrent#run raises LoadError.
    Nexo::Concurrent.send(:define_method, :require) { |*| raise LoadError, "cannot load such file -- async" }
    begin
      err = assert_raises(Nexo::MissingDependencyError) { klass.run }
      assert_match(/async/, err.message)
    ensure
      Nexo::Concurrent.send(:remove_method, :require)
    end
  ensure
    Object.send(:remove_const, :MissingAsyncCheckpoints) if defined?(MissingAsyncCheckpoints)
  end

  # Spec 21 R3 — each newly-completed step surfaces a "checkpoint"-typed event on
  # the existing event log/notification seam (name-only data); an all-persisted
  # re-run adds no new checkpoint events.
  def test_emits_one_checkpoint_event_per_newly_persisted_step_and_none_on_a_re_run
    klass = Class.new(Nexo::Workflow) do
      def call(_payload) = checkpoint_all(a: -> { 1 }, b: -> { 2 })
    end
    Object.const_set(:CheckpointEvents, klass)

    run = klass.run
    checkpoint_events = run.events.select { |e| e["type"] == "checkpoint" }
    assert_equal 2, checkpoint_events.size
    assert_equal %w[a b], checkpoint_events.map { |e| e["data"][:name] }.sort
    checkpoint_events.each { |e| assert_equal(["name"], e["data"].keys.map(&:to_s)) }

    # A second pass finds both already persisted — nothing new is emitted.
    before = run.events.size
    klass.new(run).checkpoint_all(a: -> { flunk "must not re-run" }, b: -> { flunk "must not re-run" })
    assert_equal before, run.events.size
  ensure
    Object.send(:remove_const, :CheckpointEvents) if defined?(CheckpointEvents)
  end
end
