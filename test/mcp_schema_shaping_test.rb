# frozen_string_literal: true

require "test_helper"

# 0.14: an MCP tool the gate can never authorize is left out of the schema.
class McpSchemaShapingTest < Minitest::Test
  def test_never_allows_mcp_is_true_only_under_read_only_for_unlisted_names
    read_only = Nexo::Permissions.new(mode: :read_only, mcp_allow: %w[search])

    refute read_only.never_allows_mcp?("search")
    refute read_only.never_allows_mcp?(:search)
    assert read_only.never_allows_mcp?("send_email")
    %i[auto ask approve].each do |mode|
      refute Nexo::Permissions.new(mode: mode).never_allows_mcp?("send_email"), mode.to_s
    end
  end
end
