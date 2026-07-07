# frozen_string_literal: true

module Nexo
  # The authorization gate for a sandbox's capabilities. Each tool asks
  # +authorize!+ before it touches the sandbox, so gating is provider-independent
  # and does not rely on any framework callback.
  #
  # Modes:
  # * +:auto+      — allow everything.
  # * +:read_only+ — allow +:read+/+:glob+, deny +:write+/+:shell+/+:fetch+ (the default).
  # * +:ask+       — defer to +on_ask+; a truthy return allows, anything else denies.
  #
  # Capabilities are +:read+, +:glob+, +:write+, +:shell+, +:fetch+. Anything
  # listed in +allow:+ is permitted regardless of mode.
  class Permissions
    MODES = %i[auto read_only ask].freeze

    # Raised when a capability is not authorized. Tools rescue this and return
    # +{ error: ... }+ so the agent loop continues.
    class Denied < StandardError; end

    # The configured Nexo permission mode (one of {MODES}). Read by the agent to
    # map onto an opt-in backend's own permission vocabulary (see
    # +Agent#permission_mode+).
    attr_reader :mode

    # +ask_when:+ is an optional +->(capability, detail)+ predicate that scopes
    # *which* actions actually prompt under +:ask+: when it returns falsey the
    # action is auto-allowed without calling +on_ask+; truthy (or when unset)
    # falls through to +on_ask+ exactly as before. It only ever *narrows* what is
    # auto-allowed from the "ask for everything" baseline — it never widens
    # authority. Applies to {#authorize!} only, not {#authorize_mcp!}.
    def initialize(mode: :read_only, allow: %i[read glob], mcp_allow: [], on_ask: nil, ask_when: nil)
      raise ArgumentError, "unknown mode #{mode}" unless MODES.include?(mode)

      @mode = mode
      @allow = allow
      @mcp_allow = mcp_allow.map(&:to_s)
      @on_ask = on_ask
      @ask_when = ask_when
    end

    # Authorizes +capability+ (with optional +detail+ passed to an +:ask+ hook).
    # Returns +true+ when allowed; raises {Denied} otherwise.
    def authorize!(capability, detail = nil)
      return true if @allow.include?(capability)

      case @mode
      when :auto
        true
      when :read_only
        if %i[write shell fetch].include?(capability)
          raise Denied, "#{capability} denied in read_only mode"
        end
        true
      when :ask
        # Scoped-ask: when ask_when says this action doesn't need a prompt,
        # auto-allow without calling on_ask. Unset ask_when = ask for everything.
        return true if @ask_when && !@ask_when.call(capability, detail)

        unless @on_ask&.call(capability, detail)
          raise Denied, "#{capability} (#{detail}) denied by user"
        end
        true
      end
    end

    # Authorizes an MCP tool *call* by name. A deliberate sibling of {#authorize!}
    # on a separate capability axis: an MCP tool runs inside the MCP server,
    # outside the sandbox, so this gates the authority to *invoke* it — a different
    # guarantee than sandbox capability. Fails closed under +:read_only+ (nothing
    # allowed unless the exact +tool_name+ is listed in +mcp_allow+).
    #
    # * +:auto+      — allow every MCP tool.
    # * +:read_only+ — allow only names in +mcp_allow+ (default +[]+ ⇒ deny all).
    # * +:ask+       — defer to +on_ask+ with +(:mcp, {tool:, args:})+; a truthy
    #   return allows, anything else denies.
    #
    # Returns +true+ when allowed; raises {Denied} otherwise.
    def authorize_mcp!(tool_name, args = {})
      name = tool_name.to_s

      case @mode
      when :auto
        true
      when :read_only
        return true if @mcp_allow.include?(name)

        raise Denied, "mcp tool #{name} denied in read_only mode (not in mcp_allow)"
      when :ask
        unless @on_ask&.call(:mcp, {tool: name, args: args})
          raise Denied, "mcp tool #{name} denied by user"
        end
        true
      end
    end
  end
end
