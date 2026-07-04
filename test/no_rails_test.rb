# frozen_string_literal: true

require "test_helper"

# The core must run in plain Ruby with no Rails loaded — this is the default
# test environment. Requiring "nexo_ai" (via test_helper) must not raise.
class NoRailsTest < Minitest::Test
  def test_rails_is_not_loaded_in_the_core_suite
    refute defined?(::Rails::Engine), "the core suite must run with no Rails present"
  end

  def test_version_is_a_string
    assert_kind_of String, Nexo::VERSION
  end

  def test_config_works_without_rails
    Nexo.reset_config!

    assert_equal :virtual, Nexo.config.default_sandbox
    assert_equal "skills", Nexo.config.skills_path
  end

  # Spec 10: Nexo::Session is a plain-Ruby, Zeitwerk-autoloaded class. Its durable
  # (ActiveRecord) path is guarded, so resuming a session with no host chat model
  # present falls back to the in-memory MemoryStore rather than referencing an AR
  # constant — proving require "nexo" stays Rails-optional.
  def test_session_falls_back_to_the_in_memory_store_without_a_host_model
    Nexo.reset_config!
    Nexo::Session::MemoryStore.reset!

    refute Object.const_defined?(Nexo.config.session_chat_model),
      "this test assumes no acts_as_chat host model is loaded"

    agent_class = Class.new(Nexo::Agent) { model "gpt-4o-mini" }
    def agent_class.name = "PlainRubyAssistant"

    session = Nexo::Session.resume(agent_class, "user-1")

    assert_instance_of Nexo::Session, session
    assert_equal "PlainRubyAssistant", session.agent_name
    # A second resume of the same pair reuses the one live in-memory chat.
    assert_same session.instance_variable_get(:@chat),
      Nexo::Session.resume(agent_class, "user-1").instance_variable_get(:@chat)
  end
end
