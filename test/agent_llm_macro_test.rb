# frozen_string_literal: true

require "test_helper"

# The `llm` macro (0.16): an agent's model options are declared in
# `RubyLLM::Agent`'s own DSL and applied by building the chat through it.
class AgentLlmMacroTest < Minitest::Test
  class Plain < Nexo::Agent
    model "gpt-4o-mini"
  end

  class Tuned < Nexo::Agent
    model "gpt-4o-mini"
    instructions "Be brief."

    llm do
      temperature 0.2
      thinking effort: :high
    end
    llm { headers "X-Team" => "nexo" }
  end

  class Hotter < Tuned
    llm { temperature 0.9 }
  end

  def test_an_agent_without_the_block_has_no_options_class
    assert_nil Plain.llm
    assert_kind_of RubyLLM::Chat, Plain.new.chat
  end

  def test_declared_options_reach_the_chat
    chat = Tuned.new.chat

    assert_in_delta 0.2, chat.temperature
    assert_equal({effort: :high}, chat.thinking)
    assert_equal({"X-Team" => "nexo"}, chat.headers)
  end

  def test_nexo_still_layers_instructions_and_gated_tools
    chat = Tuned.new.chat

    assert_equal ["Be brief."], chat.messages.select { |m| m.role == :system }.map(&:content)
    refute_empty chat.tools
    assert_equal Nexo.config.tool_calls_per_round, chat.tool_options[:calls]
  end

  def test_a_subclass_starts_from_its_parents_options_and_does_not_change_them
    hotter = Hotter.new.chat

    assert_in_delta 0.9, hotter.temperature
    assert_equal({effort: :high}, hotter.thinking)
    assert_in_delta 0.2, Tuned.new.chat.temperature
  end

  def test_options_are_applied_onto_a_base_chat_without_touching_its_thread
    base = RubyLLM.chat(model: "gpt-4o-mini")
    base.add_message(role: :user, content: "earlier")

    chat = Tuned.new.chat(base: base)

    assert_same base, chat
    assert_in_delta 0.2, chat.temperature
    assert_includes chat.messages.map(&:content), "earlier"
  end

  def test_the_prompt_runs_through_the_real_loop
    stub_replies "done"

    assert_equal "done", Tuned.new.prompt("go").content
  end

  def test_what_nexo_owns_is_refused_inside_the_block
    {
      model: proc { model "gpt-4o" },
      instructions: proc { instructions "x" },
      tools: proc { tools Nexo::Tools::Shell },
      mcp: proc { mcp :server },
      skills: proc { skills :triage },
      provider_tools: proc { provider_tools :web_search },
      file_store: proc { file_store },
      code_execution: proc { code_execution }
    }.each do |name, declaration|
      error = assert_raises(Nexo::ConfigurationError, name.to_s) do
        Class.new(Nexo::Agent) { llm(&declaration) }
      end
      assert_match(/`#{name}` cannot be declared inside an `llm` block/, error.message)
    end
  end
end
