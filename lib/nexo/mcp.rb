# frozen_string_literal: true

module Nexo
  # Composes the +ruby_llm-mcp+ gem so an agent can attach one or more MCP servers
  # with a single +mcp+ class macro — no MCP client wiring by hand. A loaded server
  # contributes tools that are gated by Nexo::Permissions#authorize_mcp! before
  # the model can invoke them (see MCP::GatedTool).
  #
  # +ruby_llm-mcp+ is a SOFT (optional) dependency: it is required lazily by load!
  # the first time an MCP server is built. With the gem absent, +require "nexo"+
  # still loads cleanly; only building a client raises MissingDependencyError
  # with install guidance.
  #
  # Provider-neutral by construction: MCP servers are reached through a server (not
  # a vendor SDK), so behavior is identical on Anthropic, a local model, or anything
  # else +ruby_llm+ supports.
  module MCP
    class << self
      # Lazily loads the +ruby_llm-mcp+ gem. Idempotent (a second call is a cheap
      # no-op once the gem is loaded). Raises MissingDependencyError — naming the
      # gem and the exact remedy — when the gem is not installed. Mirrors
      # Nexo::Skills.load!.
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
      # +token:+ (Spec 18) is Nexo's own option — a static bearer String or a
      # callable (+#call+) that yields one — for an OAuth-authenticated HTTP-family
      # server (+:http+/+:sse+/+:streamable+). When present, Nexo resolves it and
      # injects an +Authorization: Bearer+ header (see #inject_auth). +token:+ is a
      # dedicated keyword, so it never enters +config:+ (nothing to strip — the
      # handoff config carries no +token+ key by construction). When absent,
      # +config:+ passes through byte-for-byte (no +headers+ key added) — +:stdio+ is
      # untouched. Nexo runs no OAuth flow, refresh, or token store: it injects a
      # header, the host owns the credential (see docs/mcp.md).
      #
      # VERIFY (Group 0, ruby_llm-mcp 1.0.0): the constructor is
      # +RubyLLM::MCP.client(name:, transport_type:, config: {})+ and the client
      # connects on construction (+start: true+ default), so it is reusable across
      # prompts until torn down with +#stop+. The HTTP-family transports read auth
      # headers from +config[:headers]+ (a Hash) and SNAPSHOT them at construction
      # (+@headers = headers || {}+, dup'd per request) — there is no per-request
      # header callback for a plain +headers+ Hash. So a callable +token:+ is
      # resolved ONCE per client build; a rotated token needs the documented
      # +Agent#close+ + fresh-prompt reconnect (Spec 6 memoizes the client).
      def build(name:, transport:, token: nil, **config)
        load!
        config = inject_auth(config, token) unless token.nil?
        client_factory.client(name: name.to_s, transport_type: transport, config: config)
      end

      # Resolves a static-or-callable token and returns +config+ with an
      # +Authorization: Bearer+ header merged under +:headers+ (the Group-0-verified
      # key). A caller's other headers are preserved; Nexo's +Authorization+ wins.
      #
      # SECURITY: the token is a live credential. It must stay out of logs, events,
      # persisted +WorkflowRun+ records, and URLs/query strings — it lives only in
      # this in-memory header Hash handed to +ruby_llm-mcp+. The event path
      # (Workflow#serializable) carries only tool +name+/+args+ and return values,
      # never connection config, so the token never reaches +emit+ (see the no-leak
      # test). Nexo does not police +ruby_llm-mcp+'s own internal logging.
      private def inject_auth(config, token)
        value = token.respond_to?(:call) ? token.call : token
        headers = (config[:headers] || {}).merge("Authorization" => "Bearer #{value}")
        config.merge(headers: headers)
      end

      # The object whose +#client+ builds the MCP client — +::RubyLLM::MCP+ in
      # production. Overridable via #stub_client_factory so an offline test can
      # inspect the exact +config:+ Nexo hands off without a live server or stubbing
      # a constant.
      def client_factory
        @client_factory || ::RubyLLM::MCP
      end

      # Swaps #client_factory to +factory+ for the duration of the block, then
      # restores it. Test-only seam (Spec 18) — keeps the +token:+ transform
      # unit-testable at the +ruby_llm-mcp+ boundary.
      def stub_client_factory(factory)
        previous = @client_factory
        @client_factory = factory
        yield
      ensure
        @client_factory = previous
      end
    end
  end
end
