# frozen_string_literal: true

require "test_helper"

# R1 (self-describing sandbox) + R2 (capability-gated Shell attach) wiring in
# Agent#chat, asserted against the ruby_llm-test fake provider (offline).
class AgentSandboxWiringTest < Minitest::Test
  def setup
    skip "agent wiring tests use the stubbed provider; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
  end

  def test_virtual_agent_has_no_shell_tool
    klass = Class.new(Nexo::Agent) do
      model "gpt-4o-mini"
      sandbox :virtual
      # :shell is granted so the permission axis cannot be what removes the
      # tool — this asserts the SANDBOX axis alone.
      permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob shell])
    end
    tool_names = klass.new.chat.tools.keys.map(&:to_s)
    refute_includes tool_names.join(" ").downcase, "shell"
  end

  def test_local_agent_has_shell_tool
    klass = Class.new(Nexo::Agent) do
      model "gpt-4o-mini"
      sandbox :local
      # A :local sandbox supports :shell, but the gate has to permit it too —
      # under the :read_only default the tool is statically denied and left off.
      permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob shell])
    end
    tool_names = klass.new(cwd: Dir.pwd).chat.tools.keys.map(&:to_s)
    assert_includes tool_names.join(" ").downcase, "shell"
  end

  def test_local_sandbox_instructions_are_injected
    klass = Class.new(Nexo::Agent) do
      model "gpt-4o-mini"
      sandbox :local
      instructions "Base agent instructions."
    end
    chat = klass.new(cwd: Dir.pwd).chat
    system_messages = chat.messages.select { |m| m.role == :system }.map(&:content)

    # Ordering: agent instructions -> sandbox instructions -> (skills).
    assert_equal "Base agent instructions.", system_messages.first
    assert(system_messages.any? { |c| c.include?("You run on the host machine") })
    assert(system_messages.any? { |c| c.include?(Dir.pwd) })
  end

  def test_virtual_sandbox_injects_no_instructions
    klass = Class.new(Nexo::Agent) do
      model "gpt-4o-mini"
      sandbox :virtual
      instructions "Only me."
    end
    system_messages = klass.new.chat.messages.select { |m| m.role == :system }.map(&:content)
    assert_equal ["Only me."], system_messages
  end
end
