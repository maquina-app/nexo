# frozen_string_literal: true

require "test_helper"

# Offline, daemon-free: asserts the SHAPE of the command Container#write runs and how
# it handles a non-zero exit. No container runtime is touched.
#
# Regression: #write used to be `sh -c 'cat > "$0"'` with the exit status discarded, so
# writing a nested path into a fresh workspace failed with
#   status: 2, stderr: "...: Directory nonexistent"
# and reported success to the caller. Local#write has always created parent directories
# and raised. Materializing anything with a directory in its path — a skill's
# `scripts/render.rb`, say — therefore silently produced nothing on a container.
class ContainerWriteTest < Minitest::Test
  # Records what would have been exec'd instead of running it.
  class Recorder < Nexo::Sandboxes::Container
    attr_reader :calls

    def initialize(status: 0, stderr: "", **opts)
      super(image: "node:22-slim", cwd: "/workspace", **opts)
      @status = status
      @stderr = stderr
      @calls = []
    end

    private

    def ensure_started! = "cid"

    def exec_stdin!(data, *cmd, timeout: 30)
      @calls << {data: data, cmd: cmd}
      {stdout: "", stderr: @stderr, status: @status}
    end
  end

  def test_write_creates_parent_directories
    sandbox = Recorder.new
    sandbox.write("scripts/render.rb", "puts 1")

    script = sandbox.calls.first[:cmd].join(" ")

    assert_includes script, "mkdir -p"
    assert_includes script, "cat >"
  end

  def test_write_guards_the_path_and_passes_content_on_stdin
    sandbox = Recorder.new
    sandbox.write("scripts/render.rb", "puts 1")
    call = sandbox.calls.first

    assert_equal "puts 1", call[:data]
    assert_includes call[:cmd], "/workspace/scripts/render.rb"
  end

  def test_write_returns_the_guarded_path
    assert_equal "/workspace/a.txt", Recorder.new.write("a.txt", "x")
  end

  def test_write_raises_on_a_non_zero_exit_instead_of_reporting_success
    sandbox = Recorder.new(status: 2, stderr: "cannot create: Directory nonexistent")

    error = assert_raises(IOError) { sandbox.write("scripts/render.rb", "puts 1") }

    assert_includes error.message, "scripts/render.rb"
    assert_includes error.message, "Directory nonexistent"
  end

  def test_write_still_refuses_to_escape_the_sandbox
    assert_raises(SecurityError) { Recorder.new.write("../escape.txt", "x") }
  end
end
