# frozen_string_literal: true

require "test_helper"

# Spec 13 — the `state` field + `checkpoint`. Offline (Memory store), no mocks of
# the subject: a real side-effect counter proves the block runs exactly once and a
# present checkpoint returns the stored value without re-running.
class WorkflowCheckpointTest < Minitest::Test
  def setup = Nexo::RunStore::Memory.reset!

  # A real side-effect counter (not a mock) proves the block runs exactly once.
  class Counter
    attr_reader :calls

    def initialize = (@calls = 0)

    def bump = (@calls += 1)
  end

  def test_checkpoint_runs_block_once_and_persists_result
    counter = Counter.new
    klass = Class.new(Nexo::Workflow) do
      define_method(:counter) { counter }
      def call(_p)
        v1 = checkpoint(:step) do
          counter.bump
          42
        end
        v2 = checkpoint(:step) do # already present -> returns 42, block skipped
          counter.bump
          99
        end
        {v1: v1, v2: v2}
      end
    end
    run = klass.run
    assert_equal 42, run.result["v1"]
    assert_equal 42, run.result["v2"]
    assert_equal 1, counter.calls # second checkpoint did NOT run its block
    assert_equal 42, run.state["step"]
  end

  def test_state_defaults_to_empty_object_and_persists_incrementally
    klass = Class.new(Nexo::Workflow) do
      def call(_p)
        checkpoint(:a) { 1 }
        checkpoint(:b) { {"nested" => [1, 2]} } # json-serializable value round-trips
        {}
      end
    end
    run = klass.run
    assert_equal 1, run.state["a"]
    assert_equal({"nested" => [1, 2]}, run.state["b"])
  end
end
