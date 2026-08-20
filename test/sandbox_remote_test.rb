# frozen_string_literal: true

require "test_helper"

# Sandboxes::Remote is pure delegation to an injected client satisfying the
# four-method contract (read/write/exec/close). A fake client records the calls
# so the test asserts the delegation without any real container.
class SandboxRemoteTest < Minitest::Test
  # Records every call and lets exec return a canned result keyed by command.
  class FakeClient
    attr_reader :calls

    def initialize(exec_results = {})
      @calls = []
      @exec_results = exec_results
    end

    def read(path)
      @calls << [:read, path]
      "contents of #{path}"
    end

    def write(path, content)
      @calls << [:write, path, content]
      true
    end

    def exec(command, timeout: nil)
      @calls << [:exec, command, timeout]
      @exec_results.fetch(command, {stdout: "", stderr: "", status: 0})
    end

    def close
      @calls << [:close]
      :closed
    end
  end

  def test_read_delegates_to_the_client
    client = FakeClient.new
    sandbox = Nexo::Sandboxes::Remote.new(client: client)

    assert_equal "contents of a.txt", sandbox.read("a.txt")
    assert_includes client.calls, [:read, "a.txt"]
  end

  def test_write_delegates_to_the_client
    client = FakeClient.new
    sandbox = Nexo::Sandboxes::Remote.new(client: client)

    sandbox.write("b.txt", "hello")

    assert_includes client.calls, [:write, "b.txt", "hello"]
  end

  def test_shell_delegates_to_exec_with_timeout
    client = FakeClient.new("uname" => {stdout: "Linux\n", stderr: "", status: 0})
    sandbox = Nexo::Sandboxes::Remote.new(client: client)

    result = sandbox.shell("uname", timeout: 12)

    assert_equal "Linux\n", result[:stdout]
    assert_includes client.calls, [:exec, "uname", 12]
  end

  def test_close_delegates_to_the_client
    client = FakeClient.new
    sandbox = Nexo::Sandboxes::Remote.new(client: client)

    assert_equal :closed, sandbox.close
    assert_includes client.calls, [:close]
  end

  # Remote runs a real remote process, so it supports :shell (unlike Virtual) —
  # which is what makes Agent#chat attach the Shell tool to a remote-backed agent.
  def test_supports_all_four_capabilities_including_shell
    sandbox = Nexo::Sandboxes::Remote.new(client: FakeClient.new)

    %i[read write shell glob].each { |cap| assert sandbox.supports?(cap), "expected :#{cap}" }
  end

  # glob expands the pattern remotely (as a positional $1, not interpolated) and
  # parses stdout lines into an array. The exact command is built with the same
  # Shellwords escaping the implementation uses, so the test tracks the contract
  # without pinning a brittle literal.
  def test_glob_parses_stdout_into_an_array
    script = 'for f in $1; do [ -e "$f" ] && echo "$f"; done'
    command = "sh -c #{Shellwords.escape(script)} sh #{Shellwords.escape("*.rb")}"
    client = FakeClient.new(command => {stdout: "a.rb\nb.rb\nc.rb\n", stderr: "", status: 0})
    sandbox = Nexo::Sandboxes::Remote.new(client: client)

    assert_equal %w[a.rb b.rb c.rb], sandbox.glob("*.rb")
    assert_includes client.calls, [:exec, command, nil]
  end

  # A model-supplied pattern with shell metacharacters is passed as inert data,
  # never parsed as a command: the built command escapes both the loop script and
  # the pattern so an injected `; rm -rf ~` cannot break out of the $1 argument.
  def test_glob_pattern_cannot_inject_commands
    client = FakeClient.new
    sandbox = Nexo::Sandboxes::Remote.new(client: client)

    sandbox.glob("x; rm -rf ~")
    command = client.calls.find { |c| c.first == :exec }[1]

    # The dangerous `; rm -rf ~` is Shellwords-escaped into a single opaque token,
    # so the outer shell never sees a bare command separator.
    refute_includes command, "; rm -rf ~"
    assert_includes command, Shellwords.escape("x; rm -rf ~")
    # The loop script (which reads the pattern through $1, preserving glob
    # expansion) is itself escaped as one token — its raw form never appears.
    script = 'for f in $1; do [ -e "$f" ] && echo "$f"; done'
    assert_includes command, Shellwords.escape(script)
  end

  # Local and Container describe their environment so a weak tool-caller knows where it
  # runs; Remote returned nil, leaving the tier most likely to surprise an agent the
  # one it knew least about.
  def test_instructions_describe_the_remote_environment_by_default
    text = Nexo::Sandboxes::Remote.new(client: FakeClient.new).instructions

    refute_nil text
    assert_includes text, "remote sandbox"
  end

  def test_instructions_can_be_supplied_by_the_shim
    text = Nexo::Sandboxes::Remote.new(
      client: FakeClient.new, instructions: "You run in an E2B sandbox, cwd /home/user."
    ).instructions

    assert_equal "You run in an E2B sandbox, cwd /home/user.", text
  end
end
