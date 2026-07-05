# frozen_string_literal: true

require "test_helper"

# The Spec 11 Rails runtime (run_later over ActiveJob, live notifications, status
# scopes/predicates, artifact access) is exercised in a separate process so the
# offline core suite never loads ActiveRecord/ActiveJob (which would flip
# RunStore.default to the AR backend and a live transport for every other test).
# The child boots AR + SQLite + the :inline queue adapter + a stubbed model, drives
# each path, and asserts on the OK markers we match here.
class WorkflowRuntimeRailsTest < Minitest::Test
  def test_rails_runtime_paths_in_isolated_process
    script = File.expand_path("support/workflow_runtime_check.rb", __dir__)

    out = nil
    success = nil
    Bundler.with_unbundled_env do
      out = `bundle exec ruby #{script} 2>&1`
      success = $?.success?
    end

    assert success, "Rails runtime subprocess failed:\n#{out}"
    assert_match(/RUN_LATER_OK/, out)
    assert_match(/SYNC_RUN_OK/, out)
    assert_match(/NOTIFICATIONS_OK/, out)
    assert_match(/HELPERS_OK/, out)
    assert_match(/ARTIFACTS_OK/, out)
  end
end
