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
      #
      # `server:` is the server's `mcp` macro name. With it, a call the server
      # refuses for want of a scope raises Nexo::AuthorizationRequired naming the
      # server and the scopes (0.16) in place of `ruby_llm`'s own error, so a
      # host has one error for "send this user to sign in", first time or wider.
      def initialize(tool:, permissions:, server: nil)
        super(tool: tool, permissions: permissions, capability: :mcp)
        @server = server
      end

      # As Nexo::GatedTool#call, turning a missing scope into
      # Nexo::AuthorizationRequired.
      def call(args = nil, **kwargs)
        super
      rescue ::RubyLLM::MCP::InsufficientScopeError => e
        raise unless @server

        raise Nexo::AuthorizationRequired.new(@server, scopes: e.scopes)
      end

      private

      # The MCP gate authorizes on the tool's name, with the arguments as detail.
      def authorize!(arguments)
        @permissions.authorize_mcp!(name, arguments)
      end
    end
  end
end
