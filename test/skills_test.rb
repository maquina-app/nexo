# frozen_string_literal: true

require "test_helper"

# Skill discovery is pure filesystem logic over a real on-disk fixture loaded by
# the (dev-dependency) ruby_llm-skills gem — no model, no network. The fixture
# lives at test/fixtures/skills/triage/SKILL.md.
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

  # Simulate ruby_llm-skills being absent: force the lazy require to raise the
  # stdlib LoadError and assert load! converts it to the actionable
  # MissingDependencyError (naming the gem + remedy), rather than leaking LoadError.
  def test_load_bang_converts_missing_gem_into_missing_dependency_error
    Nexo::Skills.stub(:require, ->(_path) { raise LoadError, "cannot load such file -- ruby_llm/skills" }) do
      error = assert_raises(Nexo::MissingDependencyError) { Nexo::Skills.load! }

      assert_match(/ruby_llm-skills/, error.message)
      assert_match(/Gemfile/, error.message)
    end
  end
end
