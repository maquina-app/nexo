# frozen_string_literal: true

require "test_helper"

# Spec 5 config additions: the concurrency switch, fan-out bound, and the
# workflow event-buffering flag. Pure config — no reactor, no model.
class ConfigurationAsyncTest < Minitest::Test
  def setup
    Nexo.reset_config!
  end

  def teardown
    Nexo.reset_config!
  end

  def test_async_defaults_are_threaded_eight_and_false
    assert_equal :threaded, Nexo.config.concurrency
    assert_equal 8, Nexo.config.max_in_flight
    assert_equal false, Nexo.config.buffer_workflow_events
  end

  def test_the_async_settings_are_configurable
    Nexo.configure do |config|
      config.concurrency = :async
      config.max_in_flight = 4
      config.buffer_workflow_events = true
    end

    assert_equal :async, Nexo.config.concurrency
    assert_equal 4, Nexo.config.max_in_flight
    assert_equal true, Nexo.config.buffer_workflow_events
  end

  def test_reset_config_restores_the_async_defaults
    Nexo.configure { |c| c.concurrency = :async }
    assert_equal :async, Nexo.config.concurrency

    Nexo.reset_config!

    assert_equal :threaded, Nexo.config.concurrency
    assert_equal 8, Nexo.config.max_in_flight
    assert_equal false, Nexo.config.buffer_workflow_events
  end
end
