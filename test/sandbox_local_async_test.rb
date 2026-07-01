# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require "async"

# Spec 5: Sandboxes::Local offload. The offload path (config concurrency :async)
# must produce results byte-for-byte identical to the inline (:threaded) path,
# and the path-escape SecurityError must still be raised in both modes. Uses a
# real temp workspace (not the host filesystem at large) with cleanup.
class SandboxLocalAsyncTest < Minitest::Test
  def setup
    Nexo.reset_config!
    @dir = Dir.mktmpdir("nexo-async")
    @sandbox = Nexo::Sandboxes::Local.new(cwd: @dir)
  end

  def teardown
    Nexo.reset_config!
    FileUtils.remove_entry(@dir) if @dir && File.directory?(@dir)
  end

  def test_threaded_and_async_paths_return_identical_results
    threaded = capture_ops
    Nexo.config.concurrency = :async
    offloaded = capture_ops

    assert_equal threaded, offloaded
  end

  def test_async_offload_runs_the_real_operations
    Nexo.config.concurrency = :async

    @sandbox.write("notes/todo.txt", "buy milk")

    assert_equal "buy milk", @sandbox.read("notes/todo.txt")
    assert_equal [File.join(@dir, "notes")], @sandbox.glob("notes")
  end

  def test_offload_still_runs_the_real_operations_inside_a_reactor
    Nexo.config.concurrency = :async
    read_back = nil
    globbed = nil

    Async do
      @sandbox.write("a.txt", "hello")
      read_back = @sandbox.read("a.txt")
      globbed = @sandbox.glob("*.txt")
    end.wait

    assert_equal "hello", read_back
    assert_equal [File.join(@dir, "a.txt")], globbed
  end

  def test_path_escape_raises_security_error_in_both_modes
    assert_raises(SecurityError) { @sandbox.read("../escape.txt") }

    Nexo.config.concurrency = :async
    assert_raises(SecurityError) { @sandbox.read("../escape.txt") }
  end

  private

  # Runs the same read/write/glob sequence and returns the results, so the
  # threaded and async paths can be asserted identical.
  def capture_ops
    @sandbox.write("data/file.txt", "content-#{@dir.hash}")
    {
      read: @sandbox.read("data/file.txt"),
      glob: @sandbox.glob("data/*.txt").map { |p| File.basename(p) }
    }
  end
end
