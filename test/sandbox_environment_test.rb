# frozen_string_literal: true

require "test_helper"

# Sandbox#environment: the probe's line protocol, its degradations, and the
# promise that a failed probe never raises. No daemon — a scripted sandbox
# stands in for the far side, so the parsing contract is asserted exactly.
class SandboxEnvironmentTest < Minitest::Test
  # Replays a canned probe result and records the command it was asked to run.
  class ScriptedSandbox < Nexo::Sandbox
    attr_reader :commands_run

    def initialize(stdout: "", raise_with: nil, shell: true)
      @stdout = stdout
      @raise_with = raise_with
      @shell = shell
      @commands_run = []
    end

    def supports?(cap) = (cap == :shell) ? @shell : true

    def shell(command, timeout: 30)
      @commands_run << command
      raise @raise_with if @raise_with

      {stdout: @stdout, stderr: "", status: 0}
    end
  end

  def test_parses_locale_and_commands_from_the_probe
    env = ScriptedSandbox.new(stdout: <<~OUT).environment
      locale=C.UTF-8
      cmd=ruby\t/usr/local/bin/ruby\truby 4.0.0 (2026-01-15) [arm64-linux]
      cmd=node\t/usr/bin/node\tv26.7.0
    OUT

    assert_equal "C.UTF-8", env[:locale]
    assert_equal "/usr/local/bin/ruby", env[:commands]["ruby"][:path]
    assert_equal "4.0.0", env[:commands]["ruby"][:version]
    assert_equal "26.7.0", env[:commands]["node"][:version]
    assert_nil env[:error]
  end

  # The container case: LANG unset, so the probe prints an empty value. That is
  # "no locale", not "the empty locale" — it must come back nil.
  def test_an_empty_locale_line_is_nil_not_empty_string
    assert_nil ScriptedSandbox.new(stdout: "locale=\n").environment[:locale]
  end

  # busybox sh prints no version at all. Presence still counts.
  def test_a_command_with_no_readable_version_is_still_present
    env = ScriptedSandbox.new(stdout: "cmd=sh\t/bin/sh\t\n").environment

    assert_equal "/bin/sh", env[:commands]["sh"][:path]
    assert_nil env[:commands]["sh"][:version]
  end

  def test_a_sandbox_without_a_shell_reports_empty_with_a_reason
    env = ScriptedSandbox.new(shell: false).environment

    assert_empty env[:commands]
    assert_equal "sandbox has no shell", env[:error]
  end

  # Diagnostics must never be the reason a run dies.
  def test_a_failing_probe_reports_the_reason_instead_of_raising
    env = ScriptedSandbox.new(raise_with: Nexo::Error.new("container start failed")).environment

    assert_empty env[:commands]
    assert_includes env[:error], "container start failed"
  end

  # A runtime prints a progress banner first and the real cause last, so the
  # first line is the least useful line.
  def test_the_reported_error_prefers_the_salient_line_not_the_first
    boom = Nexo::Error.new("container start failed\n[1/6] Fetching image\nError: The volume is read only")
    env = ScriptedSandbox.new(raise_with: boom).environment

    assert_includes env[:error], "The volume is read only"
  end

  def test_the_probe_runs_once_and_is_memoized
    sb = ScriptedSandbox.new(stdout: "locale=C.UTF-8\n")
    3.times { sb.environment }

    assert_equal 1, sb.commands_run.size
  end

  def test_probed_commands_are_caller_extensible
    sb = ScriptedSandbox.new(stdout: "")
    sb.environment(commands: %w[convert])

    assert_includes sb.commands_run.first, "for c in convert;"
  end

  def test_virtual_has_no_shell_so_it_reports_empty
    env = Nexo::Sandboxes::Virtual.new.environment

    assert_empty env[:commands]
    assert_nil env[:locale]
  end

  # The real thing, on the host that runs the suite: whatever else is true, the
  # probe finds a shell and does not error.
  def test_local_probes_the_host_for_real
    env = Nexo::Sandboxes::Local.new(cwd: Dir.pwd).environment

    assert_nil env[:error]
    assert_includes env[:commands].keys, "sh"
  end
end
