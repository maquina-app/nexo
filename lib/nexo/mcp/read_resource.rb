# frozen_string_literal: true

module Nexo
  module MCP
    # The `read_mcp_resource` tool (0.16): reads one resource from one of the
    # agent's MCP servers. Attached, with ListResources, for servers declared
    # with `resources: true`, and gated like any MCP tool.
    #
    # A read happens in the server, outside the sandbox, so it is on the MCP
    # permission axis: listing `read_mcp_resource` in `mcp_allow` lets the model
    # read ANY resource those servers offer.
    class ReadResource < ::RubyLLM::Tool
      # The most text one read returns.
      MAX_BYTES = 200_000

      description "Reads one resource from a connected MCP server and returns its text."
      parameter :server, type: :string, description: "The server's name, as list_mcp_resources prints it"
      parameter :uri, type: :string, description: "The resource's uri, as list_mcp_resources prints it"

      # `servers` maps each server's `mcp` macro name to its `RubyLLM::MCP` server.
      def initialize(servers:)
        super()
        @servers = servers
      end

      # The tool's name, the same on every agent.
      def name = "read_mcp_resource"

      # The resource's text, cut at MAX_BYTES, or `{error:}` when the server is
      # unknown, the resource is binary, or the server refuses.
      def execute(server:, uri:)
        mcp = @servers[server.to_s] or
          return {error: "no MCP server named #{server} offers resources (have: #{@servers.keys.join(", ")})"}

        content = mcp.resource(uri.to_s).content.to_s
        return {error: "#{uri} is not text"} unless content.dup.force_encoding(Encoding::UTF_8).valid_encoding?

        content.byteslice(0, MAX_BYTES).scrub("")
      rescue ::RubyLLM::Error => e
        {error: e.message}
      end
    end
  end
end
