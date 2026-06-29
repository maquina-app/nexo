# frozen_string_literal: true

module Nexo
  # The authorization gate for a sandbox's capabilities. Each tool asks
  # +authorize!+ before it touches the sandbox, so gating is provider-independent
  # and does not rely on any framework callback.
  #
  # Modes:
  # * +:auto+      — allow everything.
  # * +:read_only+ — allow +:read+/+:glob+, deny +:write+/+:shell+ (the default).
  # * +:ask+       — defer to +on_ask+; a truthy return allows, anything else denies.
  #
  # Capabilities are +:read+, +:glob+, +:write+, +:shell+. Anything listed in
  # +allow:+ is permitted regardless of mode.
  class Permissions
    MODES = %i[auto read_only ask].freeze

    # Raised when a capability is not authorized. Tools rescue this and return
    # +{ error: ... }+ so the agent loop continues.
    class Denied < StandardError; end

    def initialize(mode: :read_only, allow: %i[read glob], on_ask: nil)
      raise ArgumentError, "unknown mode #{mode}" unless MODES.include?(mode)

      @mode = mode
      @allow = allow
      @on_ask = on_ask
    end

    # Authorizes +capability+ (with optional +detail+ passed to an +:ask+ hook).
    # Returns +true+ when allowed; raises {Denied} otherwise.
    def authorize!(capability, detail = nil)
      return true if @allow.include?(capability)

      case @mode
      when :auto
        true
      when :read_only
        if %i[write shell].include?(capability)
          raise Denied, "#{capability} denied in read_only mode"
        end
        true
      when :ask
        unless @on_ask&.call(capability, detail)
          raise Denied, "#{capability} (#{detail}) denied by user"
        end
        true
      end
    end
  end
end
