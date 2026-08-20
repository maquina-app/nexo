# frozen_string_literal: true

require "test_helper"

# RubyLLM can run multiple tool calls from one assistant turn concurrently
# (:fibers via async, or :threads), defaulting to off. Nexo never surfaced it, so a
# Nexo app got sequential tool calls unless it reached around Nexo to
# RubyLLM.configure directly.
class AgentToolConcurrencyTest < Minitest::Test
  # Resolvable model id + the ruby_llm-test fake provider, matching agent_test.rb.
  class Agent < Nexo::Agent
    model "gpt-4o-mini"
    sandbox :virtual
  end

  def setup
    @previous = Nexo.config.tool_concurrency
  end

  def teardown
    Nexo.configure { |c| c.tool_concurrency = @previous }
  end

  def test_defaults_to_nil_so_ruby_llm_keeps_its_own_setting
    assert_nil Nexo::Configuration.new.tool_concurrency
  end

  def test_is_applied_to_the_chat_when_configured
    Nexo.configure { |c| c.tool_concurrency = :fibers }

    assert_equal :fibers, Agent.new.chat.concurrency
  end

  def test_leaves_the_chat_untouched_when_nil
    Nexo.configure { |c| c.tool_concurrency = nil }

    assert_nil Agent.new.chat.concurrency
  end

  # Every with_tools call resets concurrency to the chat's current value, so applying
  # it before the sandbox/MCP tools are attached would be silently undone.
  def test_survives_the_tools_being_attached
    Nexo.configure { |c| c.tool_concurrency = :threads }
    chat = Agent.new.chat

    refute_empty chat.tools
    assert_equal :threads, chat.concurrency
  end
end
