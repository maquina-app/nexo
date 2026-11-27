# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# 0.15 — `file_tools :core`: ruby_llm's own file tools over a Nexo sandbox, each
# behind Nexo's permission gate. Driven through ruby_llm's real loop.
class AgentCoreFileToolsTest < Minitest::Test
  class Editor < Nexo::Agent
    model "gpt-4o-mini"
    file_tools :core
    permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob write])
  end

  class Reader < Nexo::Agent
    model "gpt-4o-mini"
    file_tools :core
  end

  class Approving < Nexo::Agent
    model "gpt-4o-mini"
    file_tools :core
    permissions Nexo::Permissions.new(mode: :approve)
  end

  class LocalEditor < Editor
    sandbox :local
  end

  def setup
    skip "scripts the model; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    Nexo.reset_config!
  end

  def teardown = Nexo.reset_config!

  def run_calls(agent, *calls)
    stub_replies(*calls, "Done.")
    results = []
    agent.prompt("Go") { |type, payload| results << payload if type == :tool_result }
    results
  end

  def test_the_five_core_tools_replace_nexos_three
    names = Editor.new.chat.tools.keys

    assert_equal %i[edit_file list_files read_file search_files write_file], names.sort
  end

  def test_nexo_tools_remain_the_default
    plain = Class.new(Nexo::Agent) { model "gpt-4o-mini" }

    assert_equal :nexo, plain.file_tools
    assert_includes plain.new.chat.tools.keys, :"nexo--tools--read_file"
  end

  def test_a_read_only_agent_gets_no_writing_tools
    assert_equal %i[list_files read_file search_files], Reader.new.chat.tools.keys.sort
  end

  def test_list_read_and_search_reach_the_sandbox
    agent = Reader.new
    agent.sandbox.write("notes/a.md", "alpha\nneedle here\n")
    agent.sandbox.write("b.txt", "beta")
    agent.sandbox.write(".env", "SECRET=1")

    list, read, search = run_calls(agent, tool_call(:list_files), tool_call(:read_file, path: "notes/a.md"),
      tool_call(:search_files, query: "needle"))

    assert_includes list.to_s, "notes/a.md"
    assert_includes list.to_s, "b.txt"
    refute_includes list.to_s, ".env", "dotfiles are not listed"
    assert_includes read.to_s, "needle here"
    assert_includes search.to_s, "notes/a.md"
  end

  def test_a_new_file_is_written_and_an_unread_one_is_protected_even_in_memory
    agent = Editor.new
    agent.sandbox.write("existing.md", "old")

    created, clobber = run_calls(agent, tool_call(:write_file, path: "new.md", content: "fresh"),
      tool_call(:write_file, path: "existing.md", content: "overwritten"))

    assert_match(/Wrote new.md/, created.to_s)
    assert_equal "fresh", agent.sandbox.read("new.md")
    assert_match(/Read existing.md before you change it/, clobber[:error])
    assert_equal "old", agent.sandbox.read("existing.md")
  end

  def test_edit_changes_part_of_a_file_after_it_was_read
    agent = Editor.new
    agent.sandbox.write("plan.md", "step one\nstep two\n")

    _read, edit = run_calls(agent, tool_call(:read_file, path: "plan.md"),
      tool_call(:edit_file, path: "plan.md", old_text: "step two", new_text: "step 2"))

    refute edit.is_a?(Hash) && edit[:error], edit.inspect
    assert_equal "step one\nstep 2\n", agent.sandbox.read("plan.md")
  end

  def test_a_path_outside_the_sandbox_is_refused
    agent = Editor.new

    result = run_calls(agent, tool_call(:write_file, path: "../escape.md", content: "x")).first

    assert_match(/not a path inside/, result[:error])
  end

  def test_an_approve_gate_suspends_on_the_path
    stub_replies tool_call(:write_file, path: "a.md", content: "x"), "Done."

    error = assert_raises(Nexo::ApprovalRequired) { Approving.new.prompt("Write") }

    assert_equal :write, error.capability
    assert_equal "a.md", error.detail
  end

  def test_a_multi_file_edit_is_identified_by_its_whole_call
    stub_replies tool_call(:edit_file, edits: [{path: "a.md", old_text: "x", new_text: "y"}]), "Done."

    error = assert_raises(Nexo::ApprovalRequired) { Approving.new.prompt("Edit") }

    assert_match(/edit_file .*a\.md/, error.detail)
  end

  def test_the_same_tools_work_on_the_local_sandbox
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "kept.md"), "on disk")
      agent = LocalEditor.new(cwd: dir)

      list, read, written = run_calls(agent, tool_call(:list_files), tool_call(:read_file, path: "kept.md"),
        tool_call(:write_file, path: "sub/new.md", content: "made"))

      assert_includes list.to_s, "kept.md"
      assert_includes read.to_s, "on disk"
      assert_match(/Wrote sub\/new.md/, written.to_s)
      assert_equal "made", File.read(File.join(dir, "sub/new.md"))
    end
  end

  def test_an_unknown_choice_is_a_configuration_error
    odd = Class.new(Nexo::Agent) do
      model "gpt-4o-mini"
      file_tools :fancy
    end

    assert_raises(Nexo::ConfigurationError) { odd.new.chat }
  end

  # --- the store, directly -----------------------------------------------------

  def test_the_store_lists_sizes_without_digests_and_reads_with_them
    sandbox = Nexo::Sandboxes::Virtual.new
    sandbox.write("a/b.md", "hello")
    store = Nexo::SandboxFileStore.new(sandbox)

    listed = store.list.first
    assert_equal ["a/b.md", 5, nil], [listed.path, listed.byte_size, listed.digest]
    assert_equal Digest::SHA256.hexdigest("hello"), store["a/b.md"].digest
    assert_nil store["missing.md"]
    assert_raises(RubyLLM::FileNotFoundError) { store.read("missing.md") }
    assert_raises(NotImplementedError) { store.delete("a/b.md") }
    assert_empty store.list("other")
  end

  def test_a_sandbox_with_no_shell_and_no_listing_says_so
    bare = Class.new(Nexo::Sandbox).new

    assert_raises(NotImplementedError) { bare.files }
  end

  def test_a_shell_backed_sandbox_lists_through_find
    listing = Class.new(Nexo::Sandbox) do
      def supports?(_capability) = true

      def shell(command, **)
        {stdout: command.start_with?("find") ? "./b.txt\n./a/c.md\n" : "", stderr: "", status: 0}
      end
    end.new

    assert_equal %w[a/c.md b.txt], listing.files
  end
end
