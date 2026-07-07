# frozen_string_literal: true

module Nexo
  module Tools
    # Vendor-neutral web search, gated by the +:search+ capability (denied by
    # default, like +:fetch+/+:shell+). Follows the +Tools::Fetch+ shape exactly:
    # authorize first, act, and rescue +Permissions::Denied+ into +{ error: ... }+
    # so the loop never crashes.
    #
    # Nexo ships NO search provider. The query is delegated to a host-injected
    # +backend+ responding to +#search(query, **opts)+ that returns an Enumerable
    # of +{title:, url:, snippet:}+ rows (Hashes or objects responding to +#to_h+).
    # Results are count- and snippet-capped so untrusted provider output can't blow
    # the context window. It pairs with +Tools::Fetch+: search finds URLs, fetch
    # reads one.
    #
    # Backend results are UNTRUSTED model input (prompt-injection risk in snippets);
    # the backend is trust-bearing and runs in the host process, not the sandbox.
    #
    # Return shape: success is +{ results: [{title:, url:, snippet:}, …] }+ (≤8
    # rows); any denial or error is +{ error: <message> }+.
    class WebSearch < RubyLLM::Tool
      description "Search the web for a query; returns titles, URLs, and snippets."
      param :query, type: :string, required: true, desc: "The search query"

      # At most this many result rows are returned.
      MAX_RESULTS = 8
      # Each result snippet is truncated to this many characters.
      MAX_SNIPPET = 300

      # +permissions+ gates the +:search+ capability; +backend+ is the injected,
      # host-owned provider. +sandbox:+ is accepted for signature parity with the
      # other tools even though search runs in the host process, not the sandbox.
      def initialize(sandbox:, permissions:, backend:)
        @permissions = permissions
        @backend = backend
        super()
      end

      # Order of operations (every denial/error returns +{ error: }+, never raises
      # into the loop): capability gate → delegate to the backend (query-only) →
      # normalize and cap. The gate runs before the backend, so a denied search
      # never touches it.
      def execute(query:)
        @permissions.authorize!(:search, query)
        rows = Array(@backend.search(query)).first(MAX_RESULTS)
        {results: rows.map { |r| normalize(r) }}
      rescue Permissions::Denied => e
        {error: e.message}
      rescue Nexo::ApprovalRequired
        # Durable approval (Spec 16): the :approve gate on authorize!(:search, query)
        # must PAUSE the run, not become a tool error. Re-raise past the broad
        # rescue below so run_agent can catch it and suspend. (Denied above still
        # becomes {error:} — that is the intended deny contract.)
        raise
      rescue => e
        {error: "search failed: #{e.message}"}
      end

      private

      # Accepts a Hash or any object responding to +#to_h+; returns a row with
      # stringified fields and the snippet truncated to MAX_SNIPPET.
      def normalize(r)
        h = r.respond_to?(:to_h) ? r.to_h : r
        {title: h[:title].to_s, url: h[:url].to_s, snippet: h[:snippet].to_s[0, MAX_SNIPPET]}
      end
    end
  end
end
