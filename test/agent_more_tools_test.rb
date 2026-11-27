# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# 0.17 — what ruby_llm offers that Nexo had not wrapped: deleting a file,
# provider-side tools, and two MCP lookups (those are in mcp_beyond_tools_test).
class AgentMoreToolsTest < Minitest::Test
  class Editor < Nexo::Agent
    model "gpt-4o-mini"
    permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write])
  end

  class LocalEditor < Editor
    sandbox :local
  end

  # --- delete_file --------------------------------------------------------------

  def test_delete_file_is_attached_when_the_agent_may_write
    assert_includes Editor.new.chat.tools.keys, :delete_file
    refute_includes Class.new(Nexo::Agent) { model "gpt-4o-mini" }.new.chat.tools.keys, :delete_file
  end

  def test_a_file_is_deleted_through_the_gate_in_memory_and_on_disk
    agent = Editor.new
    agent.sandbox.write("old.md", "x")
    tools = agent.chat.tools

    assert_match(/Deleted|deleted/i, tools[:delete_file].call(path: "old.md").to_s)
    assert_raises(Errno::ENOENT) { agent.sandbox.read("old.md") }

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "old.md"), "x")
      LocalEditor.new(cwd: dir).chat.tools[:delete_file].call(path: "old.md")

      refute File.exist?(File.join(dir, "old.md"))
    end
  end

  def test_deleting_is_a_write_and_can_wait_for_approval
    approving = Class.new(Nexo::Agent) do
      model "gpt-4o-mini"
      permissions :approve
    end
    stub_replies tool_call(:delete_file, path: "old.md"), "Done."

    error = assert_raises(Nexo::ApprovalRequired) { approving.new.prompt("delete it") }

    assert_equal [:write, "old.md"], [error.capability, error.detail]
  end

  def test_a_sandbox_that_cannot_delete_gets_no_tool
    # A custom sandbox written before 0.17: it inherits the base #delete, which raises.
    bare = Class.new(Nexo::Sandbox) do
      def read(_path) = raise(Errno::ENOENT)

      def write(_path, _content) = nil

      def files = []
    end
    agent = Editor.new(sandbox: bare.new)

    refute agent.sandbox.deletes?
    refute_includes agent.chat.tools.keys, :delete_file
  end

  # --- provider tools -----------------------------------------------------------

  def searching(permissions)
    Class.new(Nexo::Agent) do
      model "gpt-4o-mini"
      permissions permissions
      provider_tools :web_search, capability: :search
    end
  end

  def test_a_provider_tool_is_attached_only_when_every_call_is_allowed
    allowed = Nexo::Permissions.new(mode: :read_only, allow: %i[read glob search])

    assert_equal 1, searching(allowed).new.chat.provider_tools.size
    assert_equal 1, searching(:auto).new.chat.provider_tools.size
    assert_empty searching(:read_only).new.chat.provider_tools
    assert_empty searching(:approve).new.chat.provider_tools, "Nexo cannot ask about a call it never sees"
    assert_empty searching(:ask).new.chat.provider_tools
  end

  def test_a_provider_tool_needs_a_capability_and_is_refused_in_the_llm_block
    assert_raises(Nexo::ConfigurationError) { Class.new(Nexo::Agent) { provider_tools :web_search } }
    error = assert_raises(Nexo::ConfigurationError) { Class.new(Nexo::Agent) { llm { provider_tools :web_search } } }

    assert_match(/provider_tools` macro on the agent/, error.message)
  end

  def test_the_declaration_is_inherited
    parent = searching(:auto)

    assert_equal parent.provider_tools, Class.new(parent).provider_tools
  end
end
