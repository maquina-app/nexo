# frozen_string_literal: true

require "test_helper"
require "tmpdir"

class SandboxTest < Minitest::Test
  # --- Virtual -------------------------------------------------------------

  def test_virtual_write_then_read_round_trips
    sandbox = Nexo::Sandboxes::Virtual.new

    sandbox.write("notes.txt", "hello")

    assert_equal "hello", sandbox.read("notes.txt")
  end

  def test_virtual_glob_matches_written_keys
    sandbox = Nexo::Sandboxes::Virtual.new
    sandbox.write("a.rb", "1")
    sandbox.write("b.rb", "2")
    sandbox.write("c.txt", "3")

    matches = sandbox.glob("*.rb")

    assert_equal 2, matches.size
    assert_includes matches, "/workspace/a.rb"
    assert_includes matches, "/workspace/b.rb"
  end

  def test_virtual_read_of_missing_path_raises_enoent
    sandbox = Nexo::Sandboxes::Virtual.new

    assert_raises(Errno::ENOENT) { sandbox.read("missing.txt") }
  end

  def test_virtual_shell_raises_not_implemented
    sandbox = Nexo::Sandboxes::Virtual.new

    error = assert_raises(NotImplementedError) { sandbox.shell("ls") }
    assert_match(/virtual sandbox has no shell/, error.message)
  end

  # --- Local ---------------------------------------------------------------

  def test_local_write_and_read_within_cwd
    Dir.mktmpdir do |dir|
      sandbox = Nexo::Sandboxes::Local.new(cwd: dir)

      sandbox.write("sub/file.txt", "content")

      assert_equal "content", sandbox.read("sub/file.txt")
      assert_path_exists File.join(dir, "sub/file.txt")
    end
  end

  def test_local_shell_runs_with_narrowed_env
    Dir.mktmpdir do |dir|
      sandbox = Nexo::Sandboxes::Local.new(cwd: dir)

      result = sandbox.shell("echo hi")

      assert_equal "hi\n", result[:stdout]
      assert_equal 0, result[:status]
    end
  end

  def test_local_read_outside_cwd_raises_security_error
    Dir.mktmpdir do |dir|
      sandbox = Nexo::Sandboxes::Local.new(cwd: dir)

      assert_raises(SecurityError) { sandbox.read("../escape.txt") }
    end
  end

  def test_local_write_outside_cwd_raises_security_error
    Dir.mktmpdir do |dir|
      sandbox = Nexo::Sandboxes::Local.new(cwd: dir)

      assert_raises(SecurityError) { sandbox.write("../escape.txt", "x") }
    end
  end
end
