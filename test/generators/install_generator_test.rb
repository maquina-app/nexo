# frozen_string_literal: true

require "test_helper"

# The install generator needs Rails::Generators. The core suite runs with no
# Rails present, so the entire file is guarded: when Rails generators can't be
# loaded, we register a single skipped test rather than failing the suite.
rails_generators_available =
  begin
    require "rails/generators"
    require "rails/generators/test_case"
    require "generators/nexo/install/install_generator"
    true
  rescue LoadError
    false
  end

if rails_generators_available
  class InstallGeneratorTest < Rails::Generators::TestCase
    tests Nexo::Generators::InstallGenerator
    destination File.expand_path("../tmp/install_generator", __dir__)
    setup :prepare_destination

    def test_creates_the_conventional_directories_with_keep_files
      run_generator

      assert_file "app/agents/.keep"
      assert_file "app/workflows/.keep"
      assert_file "app/skills/.keep"
    end

    def test_creates_the_provider_neutral_initializer
      run_generator

      assert_file "config/initializers/nexo.rb" do |content|
        assert_match(/Nexo\.configure/, content)
        assert_match(/ENV\["NEXO_MODEL"\]/, content)
        assert_match(/:read_only/, content)
      end
    end
  end
else
  class InstallGeneratorSkippedTest < Minitest::Test
    def test_skipped_without_rails_generators
      skip "Rails generators are not loadable; install generator test skipped"
    end
  end
end
