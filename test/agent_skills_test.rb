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

  # Skills but deliberately NO `instructions` — the case where the resume-time
  # collapse used to be skipped, letting skill instructions accumulate.
  class SkillsOnlyAgent < Nexo::Agent
    model TEST_MODEL
    skills :triage
  end

  # A subclass that overrides nothing must keep the parent's configuration.
  class SpecializedTriage < TriageAgent
  end

  # Records the (text, append:) pairs apply_instructions applies, and no-ops the
  # rest of the chat build so the test can inspect ordering offline.
  class RecordingChat
    attr_reader :applies

    def initialize = (@applies = [])

    def with_instructions(text, append: false)
      @applies << [text, append]
      self
    end

    def with_tools(*) = self
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

  # Multiple skills lines ACCUMULATE (deduped), like the mcp macro — a second
  # line no longer silently replaces the first.
  def test_skills_macro_accumulates_across_lines
    klass = Class.new(Nexo::Agent) do
      model TEST_MODEL
      skills :triage
      skills :formatting, :triage # adds :formatting, dedupes the repeat
    end
    assert_equal %i[triage formatting], klass.skills
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

  # The first system contribution is always applied with append:false — even for
  # a skills-only agent with no `instructions` — so that on a persisted-chat
  # resume the leading contribution collapses prior system messages instead of
  # letting the skill body accumulate a fresh copy every resume.
  def test_first_system_contribution_collapses_even_without_instructions
    recorder = RecordingChat.new
    SkillsOnlyAgent.new.chat(base: recorder)

    refute_empty recorder.applies
    assert_equal false, recorder.applies.first.last, "leading contribution must replace, not append"
    assert(recorder.applies.first.first.include?("Classify the issue severity"))
  end

  def test_agent_with_instructions_keeps_them_first_then_appends_skills
    recorder = RecordingChat.new
    TriageAgent.new.chat(base: recorder)

    assert_equal ["Be careful.", false], recorder.applies.first
    assert recorder.applies[1..].all? { |_text, append| append }, "later contributions append"
  end

  # A subclass that overrides nothing inherits the parent's macros (model, skills,
  # instructions) instead of silently resetting to defaults.
  def test_subclass_inherits_parent_configuration
    assert_equal TEST_MODEL, SpecializedTriage.model
    assert_equal [:triage], SpecializedTriage.skills
    assert_equal "Be careful.", SpecializedTriage.instructions
    # And it builds a working agent (no "no model set" ConfigurationError).
    assert SpecializedTriage.new.chat
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
