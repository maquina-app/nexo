# frozen_string_literal: true

require "test_helper"

class ConfigurationTest < Minitest::Test
  def setup
    Nexo.reset_config!
  end

  def teardown
    Nexo.reset_config!
  end

  def test_configure_sets_and_reads_back_all_four_settings
    Nexo.configure do |config|
      config.default_model = "some-model"
      config.default_sandbox = :local
      config.default_permissions = :auto
      config.skills_path = "/tmp/skills"
    end

    assert_equal "some-model", Nexo.config.default_model
    assert_equal :local, Nexo.config.default_sandbox
    assert_equal :auto, Nexo.config.default_permissions
    assert_equal "/tmp/skills", Nexo.config.skills_path
  end

  def test_configure_returns_the_configuration
    result = Nexo.configure { |c| c.default_model = "x" }

    assert_same Nexo.config, result
  end

  def test_unset_defaults_are_safe_and_provider_neutral
    assert_nil Nexo.config.default_model
    assert_equal :virtual, Nexo.config.default_sandbox
    assert_equal :read_only, Nexo.config.default_permissions
  end

  def test_reset_config_restores_defaults
    Nexo.configure { |c| c.default_sandbox = :local }
    assert_equal :local, Nexo.config.default_sandbox

    Nexo.reset_config!

    assert_equal :virtual, Nexo.config.default_sandbox
    assert_nil Nexo.config.default_model
  end
end
