# frozen_string_literal: true

module Nexo
  module MCP
    # Wraps an MCP tool so the chat sees an identical tool but every invocation is
    # authorized through Nexo::Permissions#authorize_mcp! first. A denied call
    # returns `{ error: ... }` (recoverable) and never raises into the loop —
    # matching the sandbox-backed tools' authorize→act→rescue-`Denied`→`{error:}`
    # shape (see `lib/nexo/tools/write_file.rb`).
    #
    # Everything except the execution method is delegated to the wrapped tool, so
    # the chat cannot tell the wrapper apart from the raw MCP tool: it reports the
    # same `name`/`description`/`parameters_schema` and serializes identically.
    #
    # VERIFIED (ruby_llm 2.2.3): a server's tools are `RubyLLM::MCP::Tool`
    # instances (a `RubyLLM::Tool` subclass). `Chat#with_tools` does not type-check
    # — it registers any object answering `qualified_name`/`namespace`/`name`/
    # `deferred?` — and the tool loop invokes `tool.call(**arguments, tool_call:)`
    # with KEYWORDS. So a delegating wrapper is accepted; `method_missing` forwards
    # every reader the chat and the provider renderers ask for.
    class GatedTool
      # Wraps `tool` (an MCP tool) so every call is authorized through
      # `permissions` (the MCP axis) before delegating.
      def initialize(tool:, permissions:)
        @tool = tool
        @permissions = permissions
      end

      # Authorizes the call by tool name, then delegates to the wrapped tool. A
      # denial is returned as `{ error: ... }` so the model can recover — never
      # raised into the loop.
      #
      # Arguments arrive as keywords from the chat loop. A single positional Hash
      # is accepted too, for direct callers. `tool_call:` is the chat's own
      # bookkeeping, not a tool argument, so the gate never sees it.
      def call(args = nil, **kwargs)
        arguments = (args || {}).to_h.merge(kwargs).transform_keys(&:to_sym)
        @permissions.authorize_mcp!(name, arguments.except(:tool_call))
        @tool.call(**arguments)
      rescue Nexo::Permissions::Denied => e
        {error: e.message}
      end

      # The wrapped tool's name — the key the gate authorizes on.
      def name = @tool.name

      # Routes `#execute` through the same gate, so the wrapper is safe whichever
      # entry point a caller uses.
      def execute(*args, **kwargs)
        call(args.first, **kwargs)
      end

      # Forward description/parameters_schema/to_h/etc. to the wrapped tool so the
      # chat serializes it exactly like the raw MCP tool — but never `execute` (see
      # above).
      def respond_to_missing?(method_name, include_private = false)
        return true if method_name == :execute

        @tool.respond_to?(method_name, include_private) || super
      end

      # Delegates any unknown method to the wrapped tool (description,
      # parameters_schema, to_h, ...), so the wrapper serializes identically. `execute`
      # is handled explicitly above and never falls through here.
      def method_missing(method_name, *args, **kwargs, &block)
        if @tool.respond_to?(method_name)
          @tool.public_send(method_name, *args, **kwargs, &block)
        else
          super
        end
      end
    end
  end
end
