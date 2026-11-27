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
