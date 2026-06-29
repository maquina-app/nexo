# frozen_string_literal: true

require "test_helper"

# nexo logs inspection through the plain-Ruby (MemoryStore) path:
# Nexo::Workflow.logs(id) finds a finished run and returns its ordered events.
class LogsTest < Minitest::Test
  class Emitter < Nexo::Workflow
    def call(_payload)
      emit(:started, step: 1)
      emit(:finished, step: 2)
      {ok: true}
    end
  end

  def test_logs_returns_the_ordered_event_array_for_a_finished_run
    run = Emitter.run

    events = Nexo::Workflow.logs(run.id)

    assert_equal %w[started finished], events.map { |ev| ev["type"] }
    assert_equal [{step: 1}, {step: 2}], events.map { |ev| ev["data"] }
  end

  def test_logs_yields_each_event_when_a_block_is_given
    run = Emitter.run

    yielded = []
    returned = Nexo::Workflow.logs(run.id) { |ev| yielded << ev["type"] }

    assert_equal %w[started finished], yielded
    assert_equal returned, Nexo::Workflow.logs(run.id)
  end
end
