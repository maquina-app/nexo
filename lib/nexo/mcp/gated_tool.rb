# frozen_string_literal: true

module Nexo
  module MCP
    # Wraps a +ruby_llm-mcp+ tool so the chat sees an identical tool but every
    # invocation is authorized through {Nexo::Permissions#authorize_mcp!} first. A
    # denied call returns +{ error: ... }+ (recoverable) and never raises into the
    # loop — matching the sandbox-backed tools' authorize→act→rescue-+Denied+→
    # +{error:}+ shape (see +lib/nexo/tools/write_file.rb+).
    #
    # Everything except the execution method is delegated to the wrapped tool, so
    # the chat cannot tell the wrapper apart from the raw MCP tool: it reports the
    # same +name+/+description+/+params_schema+ and serializes identically.
    #
    # VERIFY (Group 0, ruby_llm-mcp 1.0.0 + ruby_llm 1.16.0): +RubyLLM::Chat#with_tool+
    # does not type-check — it accepts any object responding to +#name+ — and the tool
    # loop invokes +tool.call(args)+ with a positional Hash. So a duck-typed wrapper
    # is accepted; no +RubyLLM::Tool+ subclass is required. +#call+ here mirrors that
    # entry point (a +RubyLLM::MCP::Tool+'s own +#call+ normalizes and dispatches to
    # +#execute+), and +method_missing+ forwards +description+/+params_schema+/+to_h+/
    # etc. to the wrapped tool.
    class GatedTool
      def initialize(tool:, permissions:)
        @tool = tool
        @permissions = permissions
      end

      # Authorizes the call by tool name, then delegates to the wrapped tool. A
      # denial is returned as +{ error: ... }+ so the model can recover — never
      # raised into the loop.
      def call(args = {})
        @permissions.authorize_mcp!(name, args)
        @tool.call(args)
      rescue Nexo::Permissions::Denied => e
        {error: e.message}
      end

      def name = @tool.name

      # Forward description/params_schema/to_h/etc. to the wrapped tool so the chat
      # serializes it exactly like the raw MCP tool.
      def respond_to_missing?(method_name, include_private = false)
        @tool.respond_to?(method_name, include_private) || super
      end

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
