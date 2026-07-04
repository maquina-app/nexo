# frozen_string_literal: true

module Nexo
  # Composes the +ruby_llm-mcp+ gem so an agent can attach one or more MCP servers
  # with a single +mcp+ class macro — no MCP client wiring by hand. A loaded server
  # contributes tools that are gated by {Nexo::Permissions#authorize_mcp!} before
  # the model can invoke them (see {MCP::GatedTool}).
  #
  # +ruby_llm-mcp+ is a SOFT (optional) dependency: it is required lazily by {load!}
  # the first time an MCP server is built. With the gem absent, +require "nexo"+
  # still loads cleanly; only building a client raises {MissingDependencyError}
  # with install guidance.
  #
  # Provider-neutral by construction: MCP servers are reached through a server (not
  # a vendor SDK), so behavior is identical on Anthropic, a local model, or anything
  # else +ruby_llm+ supports.
  module MCP
    class << self
      # Lazily loads the +ruby_llm-mcp+ gem. Idempotent (a second call is a cheap
      # no-op once the gem is loaded). Raises {MissingDependencyError} — naming the
      # gem and the exact remedy — when the gem is not installed. Mirrors
      # {Nexo::Skills.load!}.
      def load!
        require "ruby_llm/mcp"
      rescue LoadError
        raise MissingDependencyError,
          'MCP requires the `ruby_llm-mcp` gem. Add `gem "ruby_llm-mcp"` to your Gemfile.'
      end

      # Builds a +ruby_llm-mcp+ client from Nexo's friendly, transport-shaped macro
      # opts. +name+ and +transport+ map onto the client's +name:+/+transport_type:+;
      # **every other kwarg** is collected into the client's +config:+ hash verbatim
      # (no key renaming) — e.g. +command:+/+args:+ for +:stdio+, +url:+ for +:sse+.
      #
      # VERIFY (Group 0, ruby_llm-mcp 1.0.0): the constructor is
      # +RubyLLM::MCP.client(name:, transport_type:, config: {})+ and the client
      # connects on construction (+start: true+ default), so it is reusable across
      # prompts until torn down with +#stop+.
      def build(name:, transport:, **config)
        load!
        ::RubyLLM::MCP.client(name: name.to_s, transport_type: transport, config: config)
      end
    end
  end
end
