# frozen_string_literal: true

require "test_helper"

# Spec 5: the bounded fan-out driver. No model — the tasks are plain blocks
# (counters + a scheduler-yielding sleep) so the reactor genuinely interleaves
# them. Exercises submission-order results, the in-flight bound, fail-fast error
# propagation, and the missing-dependency guard.
class ConcurrentTest < Minitest::Test
  def setup
    Nexo.reset_config!
  end

  def teardown
    Nexo.reset_config!
  end

  def test_returns_all_results_in_submission_order
    results = Nexo.concurrent(max_in_flight: 2) do |c|
      5.times do |i|
        c.add do
          sleep(0.005)
          "result-#{i}"
        end
      end
    end

    assert_equal (0..4).map { |i| "result-#{i}" }, results
  end

  def test_never_exceeds_the_in_flight_bound
    in_flight = 0
    peak = 0

    Nexo.concurrent(max_in_flight: 2) do |c|
      5.times do
        c.add do
          in_flight += 1
          peak = in_flight if in_flight > peak
          sleep(0.005) # yields to the reactor so tasks genuinely overlap
          in_flight -= 1
          nil
        end
      end
    end

    assert_operator peak, :<=, 2, "in-flight tasks exceeded max_in_flight"
    assert_equal 2, peak, "expected the bound to actually be reached"
  end

  def test_a_failing_task_re_raises_and_is_not_swallowed
    error = assert_raises(RuntimeError) do
      Nexo.concurrent(max_in_flight: 2) do |c|
        c.add { "ok" }
        c.add { raise "boom" }
        c.add { "ok" }
      end
    end

    assert_equal "boom", error.message
  end

  def test_raises_missing_dependency_error_when_async_is_unavailable
    c = Nexo::Concurrent.new(max_in_flight: 2)
    c.add { 1 }

    # Simulate the async gem being absent: the lazy require raises LoadError,
    # which the driver must translate into a guidance-bearing Nexo error.
    c.stub(:require, ->(*) { raise LoadError, "cannot load such file -- async" }) do
      error = assert_raises(Nexo::MissingDependencyError) { c.run }
      assert_match(/async/, error.message)
    end
  end
end
