# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Sandboxes::Local#shell (0.14): the narrowed environment is real, a timeout
# kills the command, and the shell can be confined to the workspace.
class SandboxLocalShellTest < Minitest::Test
  def test_the_shell_does_not_inherit_the_host_environment
    ENV["NEXO_TEST_SECRET"] = "leaked"
    Dir.mktmpdir do |dir|
      out = Nexo::Sandboxes::Local.new(cwd: dir).shell("echo secret=$NEXO_TEST_SECRET")

      assert_equal "secret=\n", out[:stdout]
    end
  ensure
    ENV.delete("NEXO_TEST_SECRET")
  end

  def test_the_shell_sees_path_and_explicit_env
    Dir.mktmpdir do |dir|
      out = Nexo::Sandboxes::Local.new(cwd: dir, env: {TOKEN: "abc"}).shell("echo $TOKEN ${PATH:+path}")

      assert_equal "abc path\n", out[:stdout]
    end
  end

  def test_a_timed_out_command_is_killed_with_its_children
    Dir.mktmpdir do |dir|
      sandbox = Nexo::Sandboxes::Local.new(cwd: dir)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      assert_raises(Timeout::Error) { sandbox.shell("(sleep 3; echo late > late.txt) & sleep 3", timeout: 0.3) }

      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
      sleep 3.2
      refute_path_exists File.join(dir, "late.txt")
    end
  end

  def test_large_output_on_both_streams_does_not_block
    Dir.mktmpdir do |dir|
      out = Nexo::Sandboxes::Local.new(cwd: dir).shell("yes a | head -c 200000; yes b | head -c 200000 >&2")

      assert_equal 200_000, out[:stdout].bytesize
      assert_equal 200_000, out[:stderr].bytesize
      assert_equal 0, out[:status]
    end
  end

  def test_exit_status_is_reported
    Dir.mktmpdir do |dir|
      assert_equal 7, Nexo::Sandboxes::Local.new(cwd: dir).shell("exit 7")[:status]
    end
  end

  def test_an_unconfined_shell_is_reported_as_a_gap
    Dir.mktmpdir do |dir|
      sandbox = Nexo::Sandboxes::Local.new(cwd: dir)

      refute_predicate sandbox, :confined?
      assert_match(/not confined/, sandbox.hardening_gaps.first)
      assert_empty Nexo::Sandboxes::Virtual.new.hardening_gaps
    end
  end

  def test_unknown_isolation_is_a_configuration_error
    assert_raises(Nexo::ConfigurationError) { Nexo::Sandboxes::Local.new(isolation: :jail) }
  end

  # --- the sandbox contract, with a fake runner ------------------------------

  Result = Struct.new(:stdout, :stderr, :exit_code, :timed_out) do
    def timed_out? = timed_out
  end

  class FakeRunner
    attr_reader :calls

    def initialize(result, supported: true)
      @result = result
      @supported = supported
      @calls = []
    end

    def supported? = @supported

    def reason = "no namespaces here"

    def run(*command, **options)
      @calls << [command, options]
      @result
    end
  end

  def test_a_sandbox_object_runs_the_command_with_the_workspace_grants
    Dir.mktmpdir do |dir|
      runner = FakeRunner.new(Result.new("out", "err", 3, false))
      sandbox = Nexo::Sandboxes::Local.new(cwd: dir, isolation: runner, readable: ["/opt/tools"])

      out = sandbox.shell("ls", timeout: 5)

      command, options = runner.calls.first
      real = File.realpath(dir)
      assert_equal({stdout: "out", stderr: "err", status: 3}, out)
      assert_equal %w[sh -c ls], command
      assert_equal [real], options[:writable]
      assert_equal [real, "/opt/tools"], options[:readable]
      assert_equal real, options[:directory]
      assert_equal 5, options[:timeout]
      assert_nil options[:network]
      assert_empty options[:env].keys - %w[HOME LANG PATH]
      assert_predicate sandbox, :confined?
      assert_empty sandbox.hardening_gaps
      assert_match(/OS sandbox/, sandbox.instructions)
    end
  end

  def test_a_confined_timeout_raises
    Dir.mktmpdir do |dir|
      sandbox = Nexo::Sandboxes::Local.new(cwd: dir, isolation: FakeRunner.new(Result.new("", "", nil, true)))

      assert_raises(Timeout::Error) { sandbox.shell("sleep 9", timeout: 1) }
    end
  end

  def test_an_unsupported_sandbox_never_falls_back_to_the_host_shell
    Dir.mktmpdir do |dir|
      runner = FakeRunner.new(Result.new("", "", 0, false), supported: false)
      sandbox = Nexo::Sandboxes::Local.new(cwd: dir, isolation: runner)

      error = assert_raises(Nexo::ConfigurationError) { sandbox.shell("echo hi > x.txt") }

      assert_match(/no namespaces here/, error.message)
      assert_empty runner.calls
      refute_path_exists File.join(dir, "x.txt")
    end
  end

  def test_the_shell_tool_reports_a_timeout_as_an_error
    sandbox = Class.new(Nexo::Sandbox) do
      def shell(_command, timeout: 30) = raise(Timeout::Error, "command timed out after 30s and was killed")
    end.new
    tool = Nexo::Tools::Shell.new(sandbox: sandbox, permissions: Nexo::Permissions.new(mode: :auto))

    assert_equal({error: "command timed out after 30s and was killed"}, tool.execute(command: "sleep 99"))
  end

  def test_resolve_passes_local_options_through
    Dir.mktmpdir do |dir|
      sandbox = Nexo::Sandboxes.resolve({type: :local, env: {"TOKEN" => "abc"}}, cwd: dir)

      assert_equal "abc\n", sandbox.shell("echo $TOKEN")[:stdout]
      assert_equal File.expand_path(dir), sandbox.cwd
    end
  end

  # --- the real OS sandbox, when mxc is installed -----------------------------

  def test_confined_shell_cannot_write_outside_the_workspace
    skip "mxc is not installed" unless mxc_available?

    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |outside|
        sandbox = Nexo::Sandboxes::Local.new(cwd: dir, isolation: :confined)
        target = File.join(File.realpath(outside), "escape.txt")

        inside = sandbox.shell("echo ok > in.txt && cat in.txt")
        sandbox.shell("echo no > #{target}")

        assert_equal "ok\n", inside[:stdout]
        refute_path_exists target
      end
    end
  end

  # Runs on Linux in CI (Bubblewrap) as well as on macOS (Seatbelt): a confined
  # command can read neither a file outside the workspace nor the network.
  def test_confined_shell_cannot_read_outside_the_workspace_or_reach_the_network
    skip "mxc is not installed" unless mxc_available?

    Dir.mktmpdir do |dir|
      Dir.mktmpdir do |outside|
        secret = File.join(File.realpath(outside), "secret.txt")
        File.write(secret, "TOP SECRET")
        sandbox = Nexo::Sandboxes::Local.new(cwd: dir, isolation: :confined, readable: [RbConfig::CONFIG["prefix"]])

        peek = sandbox.shell("cat #{secret} 2>&1")
        net = sandbox.shell(%(#{RbConfig.ruby} -rsocket -e 'Socket.tcp("1.1.1.1", 53, connect_timeout: 3) { puts "NET_OK" }' 2>&1; true))

        refute_includes peek[:stdout], "TOP SECRET"
        refute_includes net[:stdout], "NET_OK"
      end
    end
  end

  # `readable: :ruby` is the difference between a confined Ruby that cannot
  # load its own standard library and one that runs a script.
  def test_confined_shell_runs_ruby_with_the_ruby_preset
    skip "mxc is not installed" unless mxc_available?

    Dir.mktmpdir do |dir|
      script = %(#{RbConfig.ruby} -e 'require "json"; puts JSON.generate(ok: true)' 2>&1)
      granted = Nexo::Sandboxes::Local.new(cwd: dir, isolation: :confined, readable: :ruby).shell(script)

      assert_equal %({"ok":true}\n), granted[:stdout]
    end
  end

  def test_the_ruby_preset_expands_to_the_interpreter_and_gem_paths
    Dir.mktmpdir do |dir|
      sandbox = Nexo::Sandboxes::Local.new(cwd: dir, readable: [:ruby, dir, :ruby])
      readable = sandbox.instance_variable_get(:@readable)

      assert_includes readable, File.expand_path(RbConfig::CONFIG["prefix"])
      Gem.path.each { |path| assert_includes readable, File.expand_path(path) }
      assert_equal readable.uniq, readable
      assert_includes readable, File.expand_path(dir)
    end
  end

  def test_subprocess_feeds_stdin_and_still_times_out
    out, = Nexo::Sandboxes::Subprocess.capture({"PATH" => ENV["PATH"]}, "cat", timeout: 5, stdin_data: "fed")
    assert_equal "fed", out

    assert_raises(Timeout::Error) do
      Nexo::Sandboxes::Subprocess.capture({"PATH" => ENV["PATH"]}, "sleep", "30", timeout: 1, stdin_data: "x" * 200_000)
    end
  end

  private

  def mxc_available?
    require "mxc"
    ::RubyLLM::Sandbox.resolve(::MXC::Sandbox.new).supported?
  rescue LoadError
    false
  end
end
