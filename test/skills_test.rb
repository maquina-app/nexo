# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "fileutils"

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

  # --- 0.17: parsed by ruby_llm's own parser ----------------------------------

  def in_skills_dir
    Dir.mktmpdir do |root|
      Nexo.config.skills_path = root
      yield root
    end
  end

  def write_skill(root, folder, front_matter, body = "Do the thing.")
    FileUtils.mkdir_p(File.join(root, folder))
    File.write(File.join(root, folder, "SKILL.md"), "---\n#{front_matter}\n---\n\n#{body}\n")
  end

  def test_a_hyphenated_skill_exposes_what_the_agent_needs
    in_skills_dir do |root|
      write_skill(root, "email-triage", "name: email-triage\ndescription: Sorts mail\ncompatibility: needs ruby")

      skill = Nexo::Skills.find("email-triage")

      assert_equal ["email-triage", "Sorts mail", "needs ruby", "Do the thing."],
        [skill.name, skill.description, skill.compatibility, skill.content]
    end
  end

  def test_an_underscore_name_finds_the_hyphenated_folder
    in_skills_dir do |root|
      write_skill(root, "email-triage", "name: email-triage\ndescription: Sorts mail")

      assert_equal "email-triage", Nexo::Skills.find(:email_triage).name
    end
  end

  def test_a_skill_without_a_description_is_refused
    in_skills_dir do |root|
      write_skill(root, "nameless", "name: nameless")

      error = assert_raises(Nexo::Error) { Nexo::Skills.find(:nameless) }

      assert_match(/description/, error.message)
    end
  end

  def test_a_name_that_does_not_match_its_folder_is_refused
    in_skills_dir do |root|
      write_skill(root, "one", "name: two\ndescription: d")

      assert_raises(Nexo::Error) { Nexo::Skills.find(:one) }
    end
  end

  # Deprecated, removed in 0.18.
  def test_an_underscore_skill_still_loads_and_says_how_to_rename
    in_skills_dir do |root|
      write_skill(root, "email_triage", "name: email_triage\ndescription: Sorts mail")
      skill = nil

      _out, err = capture_io { skill = Nexo::Skills.find(:email_triage) }

      assert_equal "email_triage", skill.name
      assert_equal "Do the thing.", skill.content
      assert_match(/Rename the folder and its `name:` to `email-triage`/, err)
    end
  end
end
