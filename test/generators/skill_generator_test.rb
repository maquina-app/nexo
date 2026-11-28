# frozen_string_literal: true

require "test_helper"

# The skill generator needs Rails::Generators; without it the file registers one
# skipped test (see state_generator_test.rb).
rails_generators_available =
  begin
    require "rails/generators"
    require "rails/generators/test_case"
    require "generators/nexo/skill/skill_generator"
    true
  rescue LoadError
    false
  end

if rails_generators_available
  class SkillGeneratorTest < Rails::Generators::TestCase
    tests Nexo::Generators::SkillGenerator
    destination File.expand_path("../tmp/skill_generator", __dir__)
    setup :prepare_destination

    # 0.17: a skill's name is hyphenated and equal to its folder, however it was typed.
    def test_an_underscore_name_becomes_a_hyphenated_skill_that_loads
      run_generator %w[issue_triage]

      assert_file "app/skills/issue-triage/SKILL.md", /^name: issue-triage$/
      assert_file "app/skills/issue-triage/references/.keep"

      skill = Nexo::Skills::Skill.new(File.join(destination_root, "app/skills/issue-triage"))
      assert_equal "issue-triage", skill.name
    end
  end
else
  class SkillGeneratorSkippedTest < Minitest::Test
    def test_skipped_without_rails_generators
      skip "Rails generators are not available in this bundle"
    end
  end
end
