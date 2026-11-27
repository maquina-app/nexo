# frozen_string_literal: true

module Nexo
  # Composes `ruby_llm`'s built-in MCP client (`RubyLLM::MCP`, core since 2.1) so an
  # agent can attach one or more MCP servers with a single `mcp` class macro — no
  # MCP client wiring by hand. A server contributes tools that are gated by
  # Nexo::Permissions#authorize_mcp! before the model can invoke them (see
  # MCP::GatedTool).
  #
  # No extra gem is needed: the client ships with `ruby_llm`. The community
  # `ruby_llm-mcp` gem defines the same `RubyLLM::MCP` constant and must NOT be in
  # the bundle alongside it.
  #
  # Provider-neutral by construction: MCP servers are reached through a server (not
  # a vendor SDK), so behavior is identical on Anthropic, a local model, or anything
  # else `ruby_llm` supports.
  module MCP
    # Transports that reach a server over HTTP. `ruby_llm` speaks Streamable HTTP
    # and falls back for older servers itself, so every one of these is just "a URL".
    HTTP_TRANSPORTS = %i[http sse streamable streamable_http].freeze

    class << self
      # Builds a `RubyLLM::MCP` server from Nexo's friendly, transport-shaped macro
      # opts and returns it. Nothing connects yet: `ruby_llm` starts a stdio process
      # or opens the HTTP session on the first request (listing the tools), and the
      # server is reusable across prompts until torn down with `#close`.
      #
      # `transport: :stdio` takes `command:` (a String, or an argv Array) plus
      # optional `args:`, `env:` and `directory:`. An HTTP transport (`:http`,
      # `:sse`, `:streamable`) takes `url:` plus optional `headers:` and
      # `allow_http:`. `timeout:` applies to both. Any other key is handed to
      # `ruby_llm` unchanged, which raises `ArgumentError` on one it does not know.
      #
      # A stdio server's process inherits only a short list of safe variables from
      # the application (`ruby_llm` 2.2). Pass what the server needs with `env:`.
      #
      # `token:` is Nexo's own option — a static bearer String or a callable
      # (`#call`) that yields one — for an authenticated HTTP server. It is handed
      # to `ruby_llm` as its `bearer_token`, which sends `Authorization: Bearer …`
      # and reads a callable again for each request, so a rotated token is picked
      # up without reconnecting. Nexo runs no OAuth flow, refresh, or token store:
      # the host owns the credential (see docs/mcp.md).
      #
      # SECURITY: the token is a live credential. It must stay out of logs, events,
      # persisted `WorkflowRun` records, and URLs/query strings. It lives only in
      # the server's in-memory settings; the event path (Workflow#serializable)
      # carries only tool `name`/`args` and return values, never connection config,
      # so the token never reaches `emit` (see the no-leak test).
      #
      # `oauth:` (0.15) turns on `ruby_llm`'s MCP OAuth for an HTTP server: `true`,
      # or a Hash of the options `RubyLLM::MCP.oauth` takes (`client_id:`,
      # `client_secret:`, `scopes:`, `grant:`, `private_key:`, `assertion:`,
      # `identity_provider:`, `authorization_params:`). `ruby_llm` runs the whole
      # flow — discovery, registration, PKCE, refresh, DPoP — and keeps the
      # credentials in `RubyLLM.config.mcp_credential_store`. Nexo adds nothing to
      # it but the owner: `owner:` (normally `Agent.new(mcp_owner:)`) says whose
      # credentials these are. `oauth:` and `token:` are mutually exclusive.
      def build(name:, transport:, token: nil, owner: nil, **config)
        client_factory.mcp(**settings(name: name, transport: transport, token: token, owner: owner, config: config))
      rescue ArgumentError => e
        raise ConfigurationError, "mcp :#{name} — #{e.message}"
      end

      # The object whose `#mcp` builds the server — `::RubyLLM` in production.
      # Overridable via #stub_client_factory so an offline test can inspect the
      # exact settings Nexo hands off without a live server or stubbing a constant.
      def client_factory
        @client_factory || ::RubyLLM
      end

      # Swaps #client_factory to `factory` for the duration of the block, then
      # restores it. Test-only seam — keeps the settings mapping unit-testable at
      # the `ruby_llm` boundary.
      def stub_client_factory(factory)
        previous = @client_factory
        @client_factory = factory
        yield
      ensure
        @client_factory = previous
      end

      private

      # Maps the macro opts onto the keywords `RubyLLM.mcp` takes.
      def settings(name:, transport:, token:, config:, owner: nil)
        config = config.dup
        mapped = {name: name.to_s}
        oauth = config.delete(:oauth)

        if transport.to_sym == :stdio
          command = Array(config.delete(:command)) + Array(config.delete(:args))
          raise ConfigurationError, "mcp :#{name} — a :stdio server needs a `command:`" if command.empty?
          mapped[:command] = command.map(&:to_s)
          raise ConfigurationError, "mcp :#{name} — `oauth:` needs an HTTP transport, not :stdio" if oauth
        elsif HTTP_TRANSPORTS.include?(transport.to_sym)
          mapped[:bearer_token] = bearer(token) unless token.nil?
          mapped[:oauth] = oauth_settings(name, oauth, owner, token) if oauth
        else
          raise ConfigurationError,
            "mcp :#{name} — unknown transport #{transport.inspect} (use :stdio, :http, :sse or :streamable)"
        end

        mapped.merge(config)
      end

      # The `oauth:` Hash handed to `ruby_llm`, with the owner filled in.
      #
      # `ruby_llm` files credentials under "<owner>@<server url>", taking the
      # owner's GlobalID when it has one and `to_s` otherwise. An object with
      # neither a GlobalID nor a meaningful `to_s` would be filed under its
      # inspect string — a different key in every process, so the credentials
      # could never be found again. Refuse that here.
      def oauth_settings(name, oauth, owner, token)
        raise ConfigurationError, "mcp :#{name} — use `oauth:` or `token:`, not both" unless token.nil?

        oauth = (oauth == true) ? {} : oauth.to_h
        owner = oauth[:owner] if owner.nil?
        return oauth.except(:owner) if owner.nil?

        unless owner.respond_to?(:to_gid) || [String, Symbol, Integer].any? { |type| owner.is_a?(type) }
          raise ConfigurationError,
            "mcp :#{name} — the OAuth owner must be a String, Symbol, Integer or a record with a GlobalID " \
            "(got #{owner.class}); its credentials are stored under it"
        end
        oauth.merge(owner: -> { owner })
      end

      # Whether a server declared with these `mcp` macro options needs a PERSON to
      # authorize it before it can be used: OAuth with the authorization-code
      # grant. The client-credentials and JWT-bearer grants fetch a token by
      # themselves on the first request.
      def user_authorized?(config)
        oauth = config[:oauth]
        return false unless oauth

        oauth = {} if oauth == true
        grant = oauth[:grant] || ((oauth[:assertion] || oauth[:identity_provider]) ? :jwt_bearer : :authorization_code)
        grant.to_sym == :authorization_code
      end
      public :user_authorized?

      # `ruby_llm` reads a Proc again for each request; any other callable is
      # wrapped in one so it gets the same treatment.
      def bearer(token)
        token.respond_to?(:call) ? -> { token.call } : token
      end
    end
  end
end
