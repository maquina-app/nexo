# frozen_string_literal: true

require "test_helper"

# Tools are tested against the deterministic in-memory Virtual sandbox — no host
# filesystem, no model. The denial path is asserted as a returned { error: ... },
# never a raised exception.
class ToolsTest < Minitest::Test
  def setup
    @sandbox = Nexo::Sandboxes::Virtual.new
    @read_only = Nexo::Permissions.new(mode: :read_only)
    @auto = Nexo::Permissions.new(mode: :auto, allow: %i[read glob write shell])
  end

  def test_read_file_returns_content_for_a_written_file
    @sandbox.write("a.txt", "hello")
    tool = Nexo::Tools::ReadFile.new(sandbox: @sandbox, permissions: @read_only)

    assert_equal "hello", tool.execute(path: "a.txt")
  end

  def test_read_file_returns_error_hash_for_a_missing_file
    tool = Nexo::Tools::ReadFile.new(sandbox: @sandbox, permissions: @read_only)

    result = tool.execute(path: "nope.txt")

    assert_kind_of Hash, result
    assert result[:error]
  end

  def test_write_file_under_read_only_returns_error_and_does_not_write
    tool = Nexo::Tools::WriteFile.new(sandbox: @sandbox, permissions: @read_only)

    result = tool.execute(path: "a.txt", content: "x")

    assert result[:error]
    assert_raises(Errno::ENOENT) { @sandbox.read("a.txt") }
  end

  def test_write_file_under_auto_writes_and_returns_ok
    tool = Nexo::Tools::WriteFile.new(sandbox: @sandbox, permissions: @auto)

    result = tool.execute(path: "a.txt", content: "x")

    assert_equal({ok: true, path: "a.txt"}, result)
    assert_equal "x", @sandbox.read("a.txt")
  end

  def test_glob_returns_files_hash
    @sandbox.write("a.rb", "1")
    @sandbox.write("b.rb", "2")
    tool = Nexo::Tools::Glob.new(sandbox: @sandbox, permissions: @read_only)

    result = tool.execute(pattern: "*.rb")

    assert_equal 2, result[:files].size
  end

  def test_shell_on_virtual_sandbox_returns_error_not_raise
    tool = Nexo::Tools::Shell.new(sandbox: @sandbox, permissions: @auto)

    result = tool.execute(command: "ls")

    assert_kind_of Hash, result
    assert_match(/no shell/, result[:error])
  end

  def test_shell_denied_under_read_only_returns_error
    tool = Nexo::Tools::Shell.new(sandbox: @sandbox, permissions: @read_only)

    result = tool.execute(command: "ls")

    assert result[:error]
  end
end
