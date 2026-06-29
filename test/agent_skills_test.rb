# frozen_string_literal: true

require "test_helper"

# Agent + skills wiring, asserted against the ruby_llm-test fake provider (no
# network, no live model). Skill loading uses the real on-disk fixture via the
# real (dev-dependency) ruby_llm-skills gem.
class AgentSkillsTest < Minitest::Test
  TEST_MODEL = "gpt-4o-mini"
  FIXTURES = File.expand_path("fixtures/skills", __dir__)

  class TriageAgent < Nexo::Agent
    model TEST_MODEL
    instructions "Be careful."
    skills :triage
  end

  class PlainAgent < Nexo::Agent
    model TEST_MODEL
  end

  def setup
    skip "agent wiring tests use the stubbed provider; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo.reset_config!
    Nexo.config.skills_path = FIXTURES
    RubyLLM::Test.reset
  end

  def teardown
    Nexo.reset_config!
  end

  def test_skills_macro_defaults_to_empty_and_records_names
    assert_equal [], PlainAgent.skills
    assert_equal [:triage], TriageAgent.skills
  end

  def test_chat_reflects_the_declared_skills_instructions
    chat = TriageAgent.new.chat
    system_text = chat.messages.select { |m| m.role == :system }.map(&:content).join("\n")

    # Base instructions still present, skill instructions layered on top.
    assert_match(/Be careful\./, system_text)
    assert_match(/Classify the issue severity/, system_text)
  end

  def test_base_instructions_come_before_skill_instructions
    chat = TriageAgent.new.chat
    system_messages = chat.messages.select { |m| m.role == :system }.map(&:content)

    assert_equal "Be careful.", system_messages.first
    assert(system_messages.any? { |c| c.include?("Classify the issue severity") })
  end

  # Simulate ruby_llm-skills being absent: force the lazy require to raise the
  # stdlib LoadError and assert the agent path surfaces MissingDependencyError
  # (a raised library-misuse error, the only kind Nexo raises).
  def test_missing_gem_surfaces_missing_dependency_error_through_the_agent
    Nexo::Skills.stub(:require, ->(_path) { raise LoadError, "cannot load such file -- ruby_llm/skills" }) do
      assert_raises(Nexo::MissingDependencyError) { TriageAgent.new.chat }
    end
  end
end
