# frozen_string_literal: true

require "test_helper"

# R3 — Shell output truncation. The tool wraps stdout/stderr through
# OutputTruncator (tail lines, strip ANSI, char cap, marker) and leaves the
# integer status untouched.
class ToolsShellTruncationTest < Minitest::Test
  # A real stub sandbox (not a mock) returning big, ANSI-laden output.
  class BigOutputSandbox < Nexo::Sandbox
    def shell(command, timeout: 30)
      {stdout: (1..1000).map { |i| "\e[32mline #{i}\e[0m" }.join("\n"), stderr: "", status: 0}
    end

    def supports?(cap) = true
  end

  def test_truncates_lines_strips_ansi_keeps_status
    tool = Nexo::Tools::Shell.new(sandbox: BigOutputSandbox.new,
      permissions: Nexo::Permissions.new(mode: :auto))
    r = tool.execute(command: "spew")
    assert_equal 0, r[:status]
    refute_includes r[:stdout], "\e["                       # ANSI stripped
    assert_includes r[:stdout], "truncated"                 # marker present
    assert_operator r[:stdout].length, :<, 20_000           # char-capped
  end

  def test_short_output_passes_through_without_marker
    sandbox = Class.new(Nexo::Sandbox) do
      def shell(command, timeout: 30) = {stdout: "just three\nshort\nlines", stderr: "", status: 7}
      def supports?(cap) = true
    end.new
    tool = Nexo::Tools::Shell.new(sandbox: sandbox, permissions: Nexo::Permissions.new(mode: :auto))
    r = tool.execute(command: "echo")
    assert_equal 7, r[:status]
    assert_equal "just three\nshort\nlines", r[:stdout]
    refute_includes r[:stdout], "truncated"
  end

  def test_truncator_keeps_the_tail
    text = (1..500).map { |i| "line #{i}" }.join("\n")
    out = Nexo::OutputTruncator.call(text, max_lines: 10)
    assert_includes out, "line 500"        # tail kept
    refute_includes out, "line 100\n"      # head dropped
    assert_includes out, "truncated 490 lines"
  end

  def test_denial_returns_error
    tool = Nexo::Tools::Shell.new(sandbox: BigOutputSandbox.new,
      permissions: Nexo::Permissions.new(mode: :read_only))
    assert tool.execute(command: "rm")[:error]
  end
end
