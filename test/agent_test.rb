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

  # Sandbox :local, model via macro. read_only by default, so :write and :shell
  # are statically denied for it.
  class LocalAgent < Nexo::Agent
    model TEST_MODEL
    sandbox :local
  end

  # :virtual, but permitted to write and shell — isolates the SANDBOX axis of the
  # tool-attach gate, since the permission axis can no longer be the cause.
  class PermissiveVirtualAgent < Nexo::Agent
    model TEST_MODEL
    sandbox :virtual
    permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write shell])
  end

  # :local and permitted to write and shell — both axes satisfied, so the full
  # sandbox toolset attaches.
  class PermissiveLocalAgent < Nexo::Agent
    model TEST_MODEL
    sandbox :local
    permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write shell])
  end

  # No model anywhere.
  class NoModelAgent < Nexo::Agent
    sandbox :virtual
  end

  # Opts out of registry validation with a matching provider.
  class AssumeAgent < Nexo::Agent
    model "gemma3:12b"
    provider :ollama
    assume_model_exists true
    sandbox :virtual
  end

  # assume_model_exists set but no provider — a guaranteed-broken config.
  class AssumeWithoutProviderAgent < Nexo::Agent
    model "gemma3:12b"
    assume_model_exists true
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

  def test_chat_attaches_sandbox_backed_tools_gating_shell_by_capability
    chat = PermissiveVirtualAgent.new.chat
    tool_classes = chat.tools.values.map(&:class)

    assert_includes tool_classes, Nexo::Tools::ReadFile
    assert_includes tool_classes, Nexo::Tools::WriteFile
    assert_includes tool_classes, Nexo::Tools::Glob
    # The :virtual sandbox has no shell, so Shell is not attached (Spec 14 R2)
    # even though this agent's gate would permit it.
    refute_includes tool_classes, Nexo::Tools::Shell
  end

  def test_local_agent_chat_attaches_shell
    chat = PermissiveLocalAgent.new(cwd: Dir.pwd).chat
    assert_includes chat.tools.values.map(&:class), Nexo::Tools::Shell
  end

  # The permission axis of the same gate: :read_only can NEVER authorize :write or
  # :shell, so neither tool is advertised — on a :local sandbox that supports both.
  # Previously they were attached and failed at call time, which cost a round trip
  # per attempt and described the agent inaccurately to the model.
  def test_read_only_agent_does_not_advertise_write_or_shell
    tool_classes = LocalAgent.new(cwd: Dir.pwd).chat.tools.values.map(&:class)

    assert_includes tool_classes, Nexo::Tools::ReadFile
    assert_includes tool_classes, Nexo::Tools::Glob
    refute_includes tool_classes, Nexo::Tools::WriteFile
    refute_includes tool_classes, Nexo::Tools::Shell
  end

  # :ask and :approve decide per call, so neither is statically deniable and both
  # keep the tools. :approve especially MUST reach the gate — that is how it
  # raises ApprovalRequired and suspends the run.
  def test_per_call_modes_still_advertise_write_and_shell
    %i[ask approve].each do |mode|
      klass = Class.new(Nexo::Agent) do
        model TEST_MODEL
        sandbox :local
        permissions Nexo::Permissions.new(mode: mode, on_ask: ->(*) { true })
      end
      tool_classes = klass.new(cwd: Dir.pwd).chat.tools.values.map(&:class)

      assert_includes tool_classes, Nexo::Tools::WriteFile, "#{mode} should keep WriteFile"
      assert_includes tool_classes, Nexo::Tools::Shell, "#{mode} should keep Shell"
    end
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

  def test_default_agent_passes_only_model_to_ruby_llm_chat
    captured = capture_chat_options { VirtualAgent.new.chat }

    assert_equal({model: TEST_MODEL}, captured)
  end

  def test_agent_with_both_macros_passes_provider_and_assume_model_exists
    captured = capture_chat_options { AssumeAgent.new.chat }

    assert_equal "gemma3:12b", captured[:model]
    assert_equal :ollama, captured[:provider]
    assert_equal true, captured[:assume_model_exists]
  end

  def test_assume_model_exists_without_provider_raises_configuration_error
    error = assert_raises(Nexo::ConfigurationError) { AssumeWithoutProviderAgent.new }

    assert_match(/assume_model_exists/, error.message)
    assert_match(/provider/, error.message)
  end

  def test_assume_model_exists_macro_read_write_semantics
    klass = Class.new(Nexo::Agent)

    assert_equal false, klass.assume_model_exists

    klass.assume_model_exists true
    assert_equal true, klass.assume_model_exists

    klass.assume_model_exists false
    assert_equal false, klass.assume_model_exists
  end

  def test_provider_macro_read_write_semantics
    klass = Class.new(Nexo::Agent)

    assert_nil klass.provider

    klass.provider :ollama
    assert_equal :ollama, klass.provider
  end

  def test_prompt_runs_chat_ask_with_stubbed_response
    RubyLLM::Test.stub_response("review complete")

    response = VirtualAgent.new.prompt("Review it")

    assert_equal "review complete", response.content
  end

  # A sandbox that records its teardown, so we can assert Agent#close releases it
  # (a container/remote-backed sandbox otherwise leaks when the caller only knows
  # to call agent.close).
  class RecordingSandbox < Nexo::Sandbox
    attr_reader :closed_count

    def initialize
      @closed_count = 0
    end

    def close
      @closed_count += 1
    end
  end

  def test_close_releases_an_owned_sandbox
    sandbox = RecordingSandbox.new
    klass = Class.new(Nexo::Agent) do
      model TEST_MODEL
      sandbox sandbox # class-configured => the agent owns it
    end

    klass.new.close

    assert_equal 1, sandbox.closed_count
  end

  def test_close_does_not_release_a_borrowed_sandbox
    sandbox = RecordingSandbox.new
    # Injected via sandbox: (as Workflow#run_agent shares the run's sandbox) =>
    # borrowed, so the agent must leave teardown to the injector.
    agent = Nexo::Agent.new(model: TEST_MODEL, sandbox: sandbox)

    agent.close

    assert_equal 0, sandbox.closed_count
  end

  def test_close_is_idempotent_and_survives_a_raising_owned_sandbox
    raising = Class.new(Nexo::Sandbox) do
      def close = raise "boom"
    end.new
    klass = Class.new(Nexo::Agent) do
      model TEST_MODEL
      sandbox raising
    end
    agent = klass.new

    agent.close # must not raise out of close
    agent.close
  end

  private

  # Captures the kwargs a block's `Agent#chat` hands to `RubyLLM.chat` while
  # still returning a resolvable chat (built with the fake provider's test
  # model) so the rest of `#chat` — `with_instructions`/`with_tools` — succeeds
  # regardless of the captured, possibly-unregistered, model options.
  def capture_chat_options
    captured = nil
    original = RubyLLM.method(:chat)
    stub = lambda do |**opts|
      captured = opts
      original.call(model: TEST_MODEL)
    end
    RubyLLM.stub(:chat, stub) { yield }
    captured
  end
end
