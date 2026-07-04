# frozen_string_literal: true

require "test_helper"

# The Rails-only Nexo::Session persistence path is exercised in a separate
# process so the offline core suite never loads ActiveRecord (which would flip
# Session#hydrate / RunStore.default to the AR backend for every other test).
# The child boots ActiveRecord + SQLite + ruby_llm's acts_as_chat host models
# with a STUBBED model, runs cold/warm resumes, and asserts recall, addressing,
# instruction idempotency, and tool re-attach; we assert on its OK markers here.
class SessionTest < Minitest::Test
  def test_persisted_session_recalls_prior_turns_in_isolated_process
    script = File.expand_path("support/session_model_check.rb", __dir__)

    out = nil
    success = nil
    Bundler.with_unbundled_env do
      out = `bundle exec ruby #{script} 2>&1`
      success = $?.success?
    end

    assert success, "session AR subprocess failed:\n#{out}"
    assert_match(/COLD_PROMPT_OK/, out)
    assert_match(/ADDRESSING_OK/, out)
    assert_match(/WARM_RECALL_OK/, out)
    assert_match(/DISTINCT_THREAD_OK/, out)
    assert_match(/TOOLS_REATTACHED_OK/, out)
    assert_match(/CLOSE_OK/, out)
  end
end
