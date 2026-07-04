# frozen_string_literal: true

require "test_helper"

# The plain-Ruby Nexo::Session path: no ActiveRecord, an in-memory thread that
# lives for the process only (Nexo::Session::MemoryStore). Proves the
# Rails-optional guard holds — require "nexo" stays AR-free and Session#hydrate
# falls back to the memory backend — and that a resumed session continues the
# same live thread. The model is stubbed (ruby_llm-test); no network.
class SessionMemoryTest < Minitest::Test
  TEST_MODEL = "gpt-4o-mini"

  class Assistant < Nexo::Agent
    model TEST_MODEL
    instructions "You are a helpful assistant with memory."
  end

  def setup
    skip "session tests use the stubbed provider; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo::Session::MemoryStore.reset!
    RubyLLM::Test.reset
  end

  def test_without_a_host_chat_model_the_session_uses_the_in_memory_backend
    # The durable (AR) path applies only when BOTH ActiveRecord AND the host chat
    # model are present — mirroring RunStore's two-part guard. The core suite may
    # have ActiveRecord loaded (the generator tests require it), but no
    # acts_as_chat host model is defined, so the guard must keep the memory path.
    refute Object.const_defined?(Nexo.config.session_chat_model),
      "this test assumes no acts_as_chat host model is loaded in the core suite"

    one = Nexo::Session.resume(Assistant, "user-42")
    two = Nexo::Session.resume(Assistant, "user-42")

    # The memory backend hands both resumes the very same live chat; the durable
    # path would build a fresh persisted record per resume.
    assert_same one.instance_variable_get(:@chat), two.instance_variable_get(:@chat)
  end

  def test_resume_returns_a_session_addressed_by_agent_name_and_instance_id
    session = Nexo::Session.resume(Assistant, "user-42")

    assert_equal "SessionMemoryTest::Assistant", session.agent_name
    assert_equal "user-42", session.instance_id
  end

  def test_prompt_returns_the_response_and_appends_to_the_in_memory_thread
    RubyLLM::Test.stub_response("Nice to meet you, Mac!")

    response = Nexo::Session.resume(Assistant, "user-42").prompt("My name is Mac.")

    assert_equal "Nice to meet you, Mac!", response.content
  end

  def test_a_resumed_session_continues_the_same_live_thread
    RubyLLM::Test.stub_responses("first reply", "second reply")

    Nexo::Session.resume(Assistant, "user-42").prompt("My name is Mac.")
    # A later resume of the SAME pair reuses the one live chat held in MemoryStore,
    # so the thread carries the earlier turn forward (in-memory, process-lifetime).
    session = Nexo::Session.resume(Assistant, "user-42")
    chat = session.instance_variable_get(:@chat)
    messages_before = chat.messages.size

    session.prompt("What is my name?")

    assert_operator chat.messages.size, :>, messages_before
    contents = chat.messages.map(&:content).join(" ")
    assert_includes contents, "My name is Mac."
    assert_includes contents, "What is my name?"
  end

  def test_distinct_instance_ids_get_distinct_threads
    RubyLLM::Test.stub_responses("a", "b")

    one = Nexo::Session.resume(Assistant, "user-1")
    two = Nexo::Session.resume(Assistant, "user-2")

    refute_same one.instance_variable_get(:@chat), two.instance_variable_get(:@chat)
  end

  def test_close_is_safe_with_no_resources_held
    session = Nexo::Session.resume(Assistant, "user-42")

    assert_nil session.close # delegates to Agent#close; idempotent, no MCP/fetch held
  end
end
