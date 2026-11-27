# frozen_string_literal: true

module Nexo
  module MCP
    # The `list_mcp_resources` tool (0.16): what the agent's MCP servers offer to
    # be read — files, records, documents — as opposed to tools to be called.
    # Attached, with ReadResource, for servers declared with `resources: true`,
    # and gated like any MCP tool: under `:read_only` it must be in `mcp_allow`.
    class ListResources < ::RubyLLM::Tool
      # The most resources one call lists.
      MAX = 200

      description "Lists the resources the connected MCP servers offer to read, one per line: " \
        "server, uri, name, type. Pass server to list one server's only."
      parameter :server, type: :string, required: false, description: "A server name, to list only its resources"

      # `servers` maps each server's `mcp` macro name to its `RubyLLM::MCP` server.
      def initialize(servers:)
        super()
        @servers = servers
      end

      # The tool's name, the same on every agent.
      def name = "list_mcp_resources"

      # Lists the resources, or returns `{error:}` for an unknown server or one
      # that cannot be reached.
      def execute(server: nil)
        chosen = server.to_s.empty? ? @servers : @servers.slice(server.to_s)
        return {error: "no MCP server named #{server} offers resources (have: #{@servers.keys.join(", ")})"} if chosen.empty?

        lines = chosen.flat_map do |name, mcp|
          mcp.resources.map { |resource| [name, resource.uri, resource.name, resource.mime_type].join("\t") }
        end
        return "There are no resources." if lines.empty?

        more = lines.size - MAX
        (more.positive? ? lines.first(MAX) << "[#{more} more. Pass server to narrow the list.]" : lines).join("\n")
      rescue ::RubyLLM::Error => e
        {error: e.message}
      end
    end
  end
end
