# frozen_string_literal: true

require "test_helper"

# The Rails-only WorkflowRun model is exercised in a separate process so the
# offline core suite never loads ActiveRecord (which would flip
# RunStore.default to the AR backend for every other test). The child boots
# ActiveRecord + SQLite, runs the real migration template, and asserts the
# model's defaults and event persistence; we assert on its OK markers here.
class WorkflowRunModelTest < Minitest::Test
  def test_model_defaults_and_event_persistence_in_isolated_process
    script = File.expand_path("support/workflow_run_model_check.rb", __dir__)

    out = nil
    success = nil
    Bundler.with_unbundled_env do
      out = `bundle exec ruby #{script} 2>&1`
      success = $?.success?
    end

    assert success, "AR model subprocess failed:\n#{out}"
    assert_match(/PENDING_OK/, out)
    assert_match(/EVENTS_OK/, out)
    assert_match(/RESULT_STRING_KEYS_OK/, out)
    assert_match(/ARTIFACTS_OK/, out)
    assert_match(/STATE_OK/, out) # Spec 13
  end
end
