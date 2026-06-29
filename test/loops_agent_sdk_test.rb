# frozen_string_literal: true

require "test_helper"

# The opt-in, Anthropic-oriented loop. ruby_llm-agent_sdk is NOT installed in
# the core suite (per the spec), so RubyLLM::AgentSDK is stubbed and the lazy
# `require` is overridden — the happy path is verified against the stub, and the
# missing-gem path by forcing the require to raise LoadError.
class LoopsAgentSDKTest < Minitest::Test
  TEST_MODEL = "gpt-4o-mini"

  FakeMessage = Struct.new(:type, :payload)

  class SDKAgent < Nexo::Agent
    model TEST_MODEL
    sandbox :virtual
    permissions :auto # maps to AgentSDK :bypass_permissions
  end

  def setup
    skip "loop wiring tests use the stubbed provider; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo.reset_config!
  end

  def teardown
    Nexo.reset_config!
    # Remove the stub constant so it never leaks into another test.
    if defined?(::RubyLLM::AgentSDK)
      ::RubyLLM.send(:remove_const, :AgentSDK)
    end
  end

  # Define a recording ::RubyLLM::AgentSDK.query that captures its kwargs and
  # streams an :assistant then a terminal :result message.
  def install_recording_sdk
    sink = {}
    sdk = Module.new do
      define_singleton_method(:query) do |prompt, **kwargs, &block|
        sink[:prompt] = prompt
        sink[:kwargs] = kwargs
        block.call(FakeMessage.new(:assistant, "working"))
        block.call(FakeMessage.new(:result, "finished"))
      end
    end
    ::RubyLLM.const_set(:AgentSDK, sdk)
    sink
  end

  def test_agent_sdk_loop_calls_query_with_agents_settings
    sink = install_recording_sdk
    loop = Nexo::Loops::AgentSDK.new
    agent = SDKAgent.new(loop: loop)
    events = []

    # Override the lazy require (the gem is absent) so .query reaches the stub.
    result = loop.stub(:require, true) do
      agent.prompt("Refactor it", max_turns: 7) { |type, payload| events << [type, payload] }
    end

    assert_equal "Refactor it", sink[:prompt]
    assert_equal TEST_MODEL, sink[:kwargs][:model]
    assert_equal 7, sink[:kwargs][:max_turns]
    assert_equal :bypass_permissions, sink[:kwargs][:permission_mode]
    assert_equal %w[Read Write Edit Bash Glob Grep], sink[:kwargs][:allowed_tools]

    # The loop forwards every streamed message and returns the :result one.
    assert_equal :result, result.type
    assert_equal "finished", result.payload
    assert_includes events, [:assistant, FakeMessage.new(:assistant, "working")]
    assert_includes events, [:result, FakeMessage.new(:result, "finished")]
  end

  def test_missing_ruby_llm_agent_sdk_raises_missing_dependency_error
    loop = Nexo::Loops::AgentSDK.new
    agent = SDKAgent.new(loop: loop)

    error = loop.stub(:require, ->(_path) { raise LoadError, "cannot load such file -- ruby_llm/agent_sdk" }) do
      assert_raises(Nexo::MissingDependencyError) { agent.prompt("Go") }
    end

    assert_match(/ruby_llm-agent_sdk/, error.message)
    assert_match(/Gemfile/, error.message)
  end

  # The Nexo -> AgentSDK permission-mode mapping (decided in the spec).
  def test_permission_mode_mapping
    assert_equal :default, SDKAgent.new(permissions: Nexo::Permissions.new(mode: :read_only)).permission_mode
    assert_equal :bypass_permissions, SDKAgent.new(permissions: Nexo::Permissions.new(mode: :auto)).permission_mode
    assert_equal :default, SDKAgent.new(permissions: Nexo::Permissions.new(mode: :ask)).permission_mode
  end
end
