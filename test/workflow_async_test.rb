# frozen_string_literal: true

require "test_helper"

# Spec 5: Workflow buffered emit + fan-out via Nexo.concurrent. MemoryStore only
# (no DB, no model). A counting run double proves the buffered path saves exactly
# once while the default path saves per emit (unchanged Spec 2 behavior).
class WorkflowAsyncTest < Minitest::Test
  # Records push_event / save_events! calls so the test can assert how many times
  # the store was hit. Mirrors the RunStore run shape the workflow drives.
  class CountingRun
    attr_reader :events, :save_count, :status

    def initialize
      @events = []
      @save_count = 0
      @status = nil
    end

    def update!(attrs) = @status = attrs[:status]

    def push_event(ev) = @events << ev

    def save_events! = @save_count += 1
  end

  # A store double whose #create always returns the injected counting run.
  FakeStore = Struct.new(:run) do
    def create(**) = run
  end

  # Emits three events, then returns a result.
  class ThreeEvents < Nexo::Workflow
    def call(_payload)
      emit(:one)
      emit(:two)
      emit(:three)
      {ok: true}
    end
  end

  # Emits one event, then raises — to exercise the buffered flush on the failure
  # path (events must still flush, the original error must still propagate).
  class EmitThenRaise < Nexo::Workflow
    def call(_payload)
      emit(:before_boom)
      raise "kaboom"
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

  def test_buffered_mode_saves_events_exactly_once_and_keeps_them_all
    run = CountingRun.new

    Nexo::RunStore.stub(:default, FakeStore.new(run)) do
      ThreeEvents.run({}, buffer_events: true)
    end

    assert_equal 1, run.save_count, "buffered mode should flush exactly once"
    assert_equal %w[one two three], run.events.map { |e| e["type"] }
  end

  def test_unbuffered_mode_saves_per_emit
    run = CountingRun.new

    Nexo::RunStore.stub(:default, FakeStore.new(run)) do
      ThreeEvents.run({}, buffer_events: false)
    end

    assert_equal 3, run.save_count, "unbuffered mode saves once per emit (Spec 2)"
    assert_equal %w[one two three], run.events.map { |e| e["type"] }
  end

  def test_buffered_events_are_flushed_even_when_the_default_config_enables_it
    Nexo.config.buffer_workflow_events = true
    run = CountingRun.new

    Nexo::RunStore.stub(:default, FakeStore.new(run)) do
      ThreeEvents.run # no explicit buffer_events: → picks up the config default
    end

    assert_equal 1, run.save_count
    assert_equal 3, run.events.length
  end

  def test_buffered_events_flush_on_failure_and_the_original_error_propagates
    run = CountingRun.new

    error = Nexo::RunStore.stub(:default, FakeStore.new(run)) do
      assert_raises(RuntimeError) { EmitThenRaise.run({}, buffer_events: true) }
    end

    assert_equal "kaboom", error.message # original error, not masked by the flush
    assert_equal 1, run.save_count, "buffered events flush once even on failure"
    assert_equal %w[before_boom], run.events.map { |e| e["type"] }
  end

  def test_running_several_workflows_via_concurrent_returns_all_done_runs
    runs = Nexo.concurrent(max_in_flight: 2) do |c|
      4.times { |i| c.add { ThreeEvents.run(n: i) } }
    end

    assert_equal 4, runs.length
    assert(runs.all? { |r| r.status == "done" })
    assert(runs.all? { |r| r.events.length == 3 })
  end
end
