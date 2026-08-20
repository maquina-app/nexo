# frozen_string_literal: true

require "test_helper"

# A skill's compatibility: frontmatter reaches the model; license/allowed-tools
# deliberately do not. Real on-disk fixtures through the real ruby_llm-skills
# gem, asserted on the instruction texts the agent actually applies.
class AgentSkillCompatibilityTest < Minitest::Test
  TEST_MODEL = "gpt-4o-mini"
  FIXTURES = File.expand_path("fixtures/skills", __dir__)

  # Declares compatibility:, license: and allowed-tools:.
  class ProvisionedAgent < Nexo::Agent
    model TEST_MODEL
    skills :provisioned
  end

  # The pre-existing fixture, which sets none of them.
  class PlainSkillAgent < Nexo::Agent
    model TEST_MODEL
    skills :triage
  end

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
  end

  def teardown
    Nexo.reset_config!
  end

  def texts_for(klass)
    agent = klass.new(sandbox: Nexo::Sandboxes::Virtual.new)
    agent.send(:apply_instructions, RecordingChat.new).applies.map(&:first)
  end

  def test_compatibility_is_appended_to_the_skill_body_under_a_label
    text = texts_for(ProvisionedAgent).find { |t| t.include?("Provisioned") }

    assert_includes text, "Run `scripts/render.rb`"
    assert_includes text, "Compatibility: Requires a Ruby interpreter (>= 3.1) and a UTF-8 locale."
    # Labelled and separated, so the model can tell a requirement from a step.
    assert_match(/\n\nCompatibility: /, text)
  end

  def test_license_and_allowed_tools_are_not_surfaced
    text = texts_for(ProvisionedAgent).find { |t| t.include?("Provisioned") }

    refute_includes text, "MIT"
    refute_includes text, "allowed-tools"
  end

  # A skill without compatibility: must contribute exactly its body, byte for
  # byte — no trailing label, no added whitespace.
  def test_a_skill_without_compatibility_is_unchanged
    text = texts_for(PlainSkillAgent).find { |t| t.include?("Triage") }

    assert_equal Nexo::Skills.find(:triage).content, text
    refute_includes text, "Compatibility:"
  end

  # The helper reads through respond_to?, so a Skill-alike lacking the accessor
  # (an older ruby_llm-skills, a virtual/DB skill) degrades to the body.
  def test_a_skill_object_without_the_accessor_degrades_to_its_body
    bodyish = Struct.new(:content).new("just a body")
    agent = PlainSkillAgent.new(sandbox: Nexo::Sandboxes::Virtual.new)

    assert_equal "just a body", agent.send(:skill_instructions, bodyish)
  end

  def test_blank_compatibility_contributes_nothing
    blank = Struct.new(:content, :compatibility).new("body", "   ")
    agent = PlainSkillAgent.new(sandbox: Nexo::Sandboxes::Virtual.new)

    assert_equal "body", agent.send(:skill_instructions, blank)
  end
end
