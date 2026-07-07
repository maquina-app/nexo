# frozen_string_literal: true

require "net/http"
require "uri"
require "ipaddr"
require "resolv"

module Nexo
  module Tools
    # Read-only HTTP(S) GET, gated by the +:fetch+ capability (denied by default,
    # like +:shell+) and a host allow-list (SSRF/egress guard). Follows the
    # +ReadFile+/+WriteFile+ shape exactly: authorize first, act, and rescue
    # +Permissions::Denied+ into +{ error: ... }+ so the loop never crashes.
    #
    # Deliberately minimal: a single stdlib GET. No POST/PUT/DELETE, no crawler,
    # no cache, no rate limiter, no redirect-following. The only request header the
    # model influences is a fixed +User-Agent+. Fetched bodies are UNTRUSTED model
    # input (prompt-injection risk) and are returned raw (truncated), never parsed.
    #
    # Return shape differs from +ReadFile+ (which returns a bare String): success
    # is +{ body: <string truncated to MAX_BYTES> }+; any denial or error is
    # +{ error: <message> }+.
    class Fetch < RubyLLM::Tool
      description "Fetch the text of a web page by URL (HTTP/HTTPS GET only)."
      param :url, type: :string, required: true, desc: "Absolute http(s) URL to fetch"

      # Bodies are truncated to this many bytes (byteslice) before returning.
      MAX_BYTES = 200_000

      def initialize(sandbox:, permissions:, allow_hosts: [])
        @sandbox = sandbox
        @permissions = permissions
        @allow_hosts = allow_hosts.map(&:to_s)
        super()
      end

      # Order of checks (every denial returns +{ error: }+, never raises into the
      # loop): capability gate → scheme → host allow-list → private-address guard →
      # perform the GET. The private-address guard runs AFTER the allow-list and is
      # never bypassed, so an allow-listed +localhost+ is still refused.
      def execute(url:)
        @permissions.authorize!(:fetch, url)

        uri = URI.parse(url)
        unless %w[http https].include?(uri.scheme)
          raise Permissions::Denied, "only http(s) URLs allowed"
        end
        unless host_allowed?(uri.host)
          raise Permissions::Denied, "host #{uri.host} not in fetch allow-list"
        end
        if private_address?(uri.host)
          raise Permissions::Denied, "private/loopback address refused: #{uri.host}"
        end

        {body: get(uri).byteslice(0, MAX_BYTES)}
      rescue Permissions::Denied => e
        {error: e.message}
      rescue Nexo::ApprovalRequired
        # Durable approval (Spec 16): the :approve gate on authorize!(:fetch, url)
        # must PAUSE the run, not become a tool error. Re-raise past the broad
        # rescue below so run_agent can catch it and suspend. (Denied above still
        # becomes {error:} — that is the intended deny contract.)
        raise
      rescue => e
        {error: "fetch failed: #{e.message}"}
      end

      private

      # Subdomain-aware host match (not exact): +host+ matches an allow-list entry
      # +h+ when it equals +h+ or ends with +"." + h+. So +news.example.com+
      # permits itself and +www.news.example.com+, but never +notexample.com+ or
      # +example.com.evil.org+. Case-insensitive on the host.
      def host_allowed?(host)
        return false if host.nil?

        h = host.downcase
        @allow_hosts.any? do |entry|
          e = entry.downcase
          h == e || h.end_with?(".#{e}")
        end
      end

      # Resolve the host and refuse if any resolved address is loopback, private
      # (RFC1918), or link-local. This guard ALWAYS applies, even to an
      # allow-listed host. Resolution failure fails open to the normal connect path
      # (a bad host then fails naturally as a fetch error).
      def private_address?(host)
        Resolv.getaddresses(host).any? do |ip|
          addr = IPAddr.new(ip)
          addr.loopback? || addr.private? || addr.link_local?
        end
      rescue
        false
      end

      def get(uri)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
          open_timeout: 5, read_timeout: 10) do |http|
          http.get(uri.request_uri, {"User-Agent" => "Nexo/#{Nexo::VERSION}"}).body.to_s
        end
      end
    end
  end
end
