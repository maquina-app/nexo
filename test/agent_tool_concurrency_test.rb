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

  # --- 0.15: a cap on the tool calls one response may run ---------------------

  def test_tool_calls_per_round_defaults_to_twenty_and_reaches_the_chat
    assert_equal 20, Nexo::Configuration.new.tool_calls_per_round
    assert_equal 20, Agent.new.chat.tool_options[:calls]
  end

  def test_tool_calls_per_round_can_be_changed_or_removed
    previous = Nexo.config.tool_calls_per_round
    Nexo.configure { |c| c.tool_calls_per_round = 5 }
    assert_equal 5, Agent.new.chat.tool_options[:calls]

    Nexo.configure { |c| c.tool_calls_per_round = nil }
    assert_nil Agent.new.chat.tool_options[:calls]
  ensure
    Nexo.configure { |c| c.tool_calls_per_round = previous }
  end

  # --- the context budget is a model option (the macro was removed in 0.16) ----

  class Budgeted < Agent
    llm { context_budget per_result: 0.25, per_request: 0.7, window: 32_000 }
  end

  def test_context_budget_is_passed_to_the_chat_and_inherited
    assert_equal({per_result: 0.25, per_request: 0.7, window: 32_000}, Budgeted.new.chat.context_budget)
    assert_equal({per_result: 0.25, per_request: 0.7, window: 32_000}, Class.new(Budgeted).new.chat.context_budget)
  end

  def test_no_declaration_leaves_the_chat_budget_alone
    assert_nil Agent.new.chat.context_budget
  end

  def test_an_invalid_budget_is_refused
    assert_raises(ArgumentError) { Class.new(Agent) { llm { context_budget per_result: 2 } }.new.chat }
  end

  def test_the_removed_macro_points_at_the_llm_block
    error = assert_raises(Nexo::ConfigurationError) { Class.new(Agent) { context_budget per_result: 0.25 } }

    assert_match(/llm \{ context_budget/, error.message)
  end
end
