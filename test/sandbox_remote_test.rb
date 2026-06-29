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

  # glob runs `ls <pattern>` remotely and parses stdout lines into an array.
  def test_glob_parses_ls_stdout_into_an_array
    client = FakeClient.new("ls *.rb" => {stdout: "a.rb\nb.rb\nc.rb\n", stderr: "", status: 0})
    sandbox = Nexo::Sandboxes::Remote.new(client: client)

    assert_equal %w[a.rb b.rb c.rb], sandbox.glob("*.rb")
    assert_includes client.calls, [:exec, "ls *.rb", nil]
  end
end
