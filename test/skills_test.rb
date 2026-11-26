# frozen_string_literal: true

require "test_helper"

# Skill discovery is pure filesystem logic over a real on-disk fixture read by
# Nexo::Skills::Skill — no model, no network, no extra gem. The fixture lives at
# test/fixtures/skills/triage/SKILL.md.
class SkillsTest < Minitest::Test
  FIXTURES = File.expand_path("fixtures/skills", __dir__)

  def setup
    Nexo.reset_config!
    Nexo.config.skills_path = FIXTURES
  end

  def teardown
    Nexo.reset_config!
  end

  def test_find_loads_the_fixture_skill
    skill = Nexo::Skills.find(:triage)

    assert_equal "triage", skill.name
    assert_match(/Classify the issue severity/, skill.content)
  end

  def test_find_accepts_a_string_name
    skill = Nexo::Skills.find("triage")

    assert_equal "triage", skill.name
  end

  def test_unknown_skill_raises_error_naming_the_missing_path
    error = assert_raises(Nexo::Error) { Nexo::Skills.find(:nope) }

    assert_equal "skill not found: #{File.join(FIXTURES, "nope", "SKILL.md")}", error.message
  end
end
