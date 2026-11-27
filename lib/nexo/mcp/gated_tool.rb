# frozen_string_literal: true

module Nexo
  module MCP
    # Nexo::GatedTool on the MCP axis: every invocation of the wrapped MCP tool is
    # authorized by NAME through Nexo::Permissions#authorize_mcp! first, and a
    # denied call returns `{ error: ... }` without reaching the server.
    #
    # VERIFIED (ruby_llm 2.2.3): a server's tools are `RubyLLM::MCP::Tool`
    # instances (a `RubyLLM::Tool` subclass), called with keywords.
    class GatedTool < Nexo::GatedTool
      # Wraps `tool` (an MCP tool) so every call is authorized through
      # `permissions` (the MCP axis) before delegating.
      def initialize(tool:, permissions:)
        super(tool: tool, permissions: permissions, capability: :mcp)
      end

      private

      # The MCP gate authorizes on the tool's name, with the arguments as detail.
      def authorize!(arguments)
        @permissions.authorize_mcp!(name, arguments)
      end
    end
  end
end
