# frozen_string_literal: true

require "test_helper"

# Optional, manual, env-gated live smoke against a REAL container runtime.
# Skipped unless NEXO_LIVE=1 and the runtime binary is on PATH, so it is never
# part of the offline core suite. It exercises the full start -> write/read ->
# shell -> path-escape -> close cycle in a hardened container.
#
#   NEXO_LIVE=1 bundle exec rake test TEST=test/sandboxes/container_live_test.rb
#
# Point the runtime with NEXO_CONTAINER_RUNTIME=apple to smoke Apple's container
# CLI instead of docker.
class ContainerLiveTest < Minitest::Test
  def setup
    skip "set NEXO_LIVE=1 to run live container smoke tests" unless ENV["NEXO_LIVE"] == "1"

    @runtime = (ENV["NEXO_CONTAINER_RUNTIME"] || "docker").to_sym
    bin = Nexo::Sandboxes::Container::RUNTIMES.fetch(@runtime)
    skip "#{bin} binary not on PATH" unless system("command -v #{bin} > /dev/null 2>&1")

    @sandbox = Nexo::Sandboxes::Container.new(
      image: ENV["NEXO_CONTAINER_IMAGE"] || "alpine",
      runtime: @runtime,
      cwd: "/workspace"
    )
  end

  def teardown
    @sandbox&.close
  end

  def test_write_then_read_round_trips_under_cwd
    @sandbox.write("notes.txt", "hello from nexo")

    assert_equal "hello from nexo", @sandbox.read("notes.txt")
  end

  def test_shell_returns_stdout_and_exit_status
    ok = @sandbox.shell("echo hi")
    assert_equal "hi\n", ok[:stdout]
    assert_equal 0, ok[:status]

    boom = @sandbox.shell("exit 3")
    assert_equal 3, boom[:status]
  end

  def test_glob_lists_written_files
    @sandbox.write("a.rb", "1")
    @sandbox.write("b.rb", "2")
    @sandbox.write("c.txt", "3")

    matches = @sandbox.glob("*.rb")

    assert_includes matches, "/workspace/a.rb"
    assert_includes matches, "/workspace/b.rb"
    refute_includes matches, "/workspace/c.txt"
  end

  def test_write_outside_cwd_is_blocked
    assert_raises(SecurityError) { @sandbox.write("/etc/evil", "x") }
  end

  def test_close_removes_the_container
    @sandbox.write("touch.txt", "start it") # forces ensure_started!
    cid = @sandbox.instance_variable_get(:@cid)
    refute_nil cid

    @sandbox.close

    bin = Nexo::Sandboxes::Container::RUNTIMES.fetch(@runtime)
    still_there = system("#{bin} inspect #{cid} > /dev/null 2>&1")
    refute still_there, "container #{cid} should be gone after close"
  end
end
