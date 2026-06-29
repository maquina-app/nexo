# frozen_string_literal: true

require "test_helper"

# Agent wiring is asserted with the ruby_llm-test fake provider (installed in
# test_helper) — no network, no live model output. A resolvable model id is used
# only so RubyLLM.chat can build a chat; the suite never asserts model text.
class AgentTest < Minitest::Test
  TEST_MODEL = "gpt-4o-mini"

  # Sandbox :virtual + an explicit model. read_only by default.
  class VirtualAgent < Nexo::Agent
    model TEST_MODEL
    sandbox :virtual
    instructions "Be careful."
  end

  # Sandbox :local, model via macro.
  class LocalAgent < Nexo::Agent
    model TEST_MODEL
    sandbox :local
  end

  # No model anywhere.
  class NoModelAgent < Nexo::Agent
    sandbox :virtual
  end

  def setup
    # These assert wiring against the ruby_llm-test fake provider, which
    # test_helper installs only when NEXO_LIVE != "1". Skip first (before any
    # RubyLLM::Test reference) so a live run of the whole suite doesn't crash here.
    skip "agent wiring tests use the stubbed provider; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo.reset_config!
    RubyLLM::Test.reset
  end

  def teardown
    Nexo.reset_config!
  end

  def test_chat_attaches_all_four_sandbox_backed_tools
    chat = VirtualAgent.new.chat
    tool_classes = chat.tools.values.map(&:class)

    assert_includes tool_classes, Nexo::Tools::ReadFile
    assert_includes tool_classes, Nexo::Tools::WriteFile
    assert_includes tool_classes, Nexo::Tools::Shell
    assert_includes tool_classes, Nexo::Tools::Glob
  end

  def test_macro_instructions_appear_on_the_built_chat
    chat = VirtualAgent.new.chat
    system_message = chat.messages.find { |m| m.role == :system }

    refute_nil system_message
    assert_equal "Be careful.", system_message.content
  end

  def test_no_model_anywhere_raises_configuration_error
    error = assert_raises(Nexo::ConfigurationError) { NoModelAgent.new }

    assert_match(/model/, error.message)
  end

  def test_model_resolves_from_config_default_when_macro_absent
    Nexo.configure { |c| c.default_model = TEST_MODEL }

    agent = NoModelAgent.new

    assert_equal TEST_MODEL, agent.model
  end

  def test_local_sandbox_resolves_to_local_bound_to_cwd
    Dir.mktmpdir do |dir|
      agent = LocalAgent.new(cwd: dir)

      assert_instance_of Nexo::Sandboxes::Local, agent.sandbox
      assert_equal File.expand_path(dir), agent.sandbox.cwd
    end
  end

  def test_defaults_are_virtual_and_read_only
    agent = NoModelAgent.new(model: TEST_MODEL)

    assert_instance_of Nexo::Sandboxes::Virtual, agent.sandbox
    assert_instance_of Nexo::Permissions, agent.permissions
  end

  def test_unknown_sandbox_symbol_raises_configuration_error
    assert_raises(Nexo::ConfigurationError) do
      NoModelAgent.new(model: TEST_MODEL, sandbox: :bogus)
    end
  end

  def test_prebuilt_permissions_instance_is_accepted_as_is
    gate = Nexo::Permissions.new(mode: :ask, on_ask: ->(_c, _d) { true })

    agent = NoModelAgent.new(model: TEST_MODEL, permissions: gate)

    assert_same gate, agent.permissions
  end

  def test_prompt_runs_chat_ask_with_stubbed_response
    RubyLLM::Test.stub_response("review complete")

    response = VirtualAgent.new.prompt("Review it")

    assert_equal "review complete", response.content
  end
end
