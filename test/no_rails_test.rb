# frozen_string_literal: true

require "test_helper"

# The core must run in plain Ruby with no Rails loaded — this is the default
# test environment. Requiring "nexo_ai" (via test_helper) must not raise.
class NoRailsTest < Minitest::Test
  def test_rails_is_not_loaded_in_the_core_suite
    refute defined?(::Rails::Engine), "the core suite must run with no Rails present"
  end

  def test_version_is_a_string
    assert_kind_of String, Nexo::VERSION
  end

  def test_config_works_without_rails
    Nexo.reset_config!

    assert_equal :virtual, Nexo.config.default_sandbox
    assert_equal "skills", Nexo.config.skills_path
  end
end
