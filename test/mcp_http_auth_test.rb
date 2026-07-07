# frozen_string_literal: true

require "test_helper"

# Spec 18 — MCP over HTTP + OAuth token provider.
#
# Subject: Nexo::MCP.build's config TRANSFORM (not the gem). A fake client factory
# records the exact +config:+ ruby_llm-mcp would receive, so the offline suite proves
# header injection, token stripping, and callable resolution without a live server.
#
# Group 0 (VERIFIED, ruby_llm-mcp 1.0.0): the HTTP-family transports read auth headers
# from +config[:headers]+ (a Hash) under the +"Authorization"+ name, and snapshot them
# at construction — so a callable +token:+ resolves ONCE per build.
class McpHttpAuthTest < Minitest::Test
  # Records the config ruby_llm-mcp would receive — a real recording object at the
  # boundary, swapped in via Nexo::MCP.stub_client_factory.
  class FakeClientFactory
    attr_reader :name, :transport, :config

    def client(name:, transport_type:, config:)
      @name = name
      @transport = transport_type
      @config = config
      :fake_client
    end
  end

  def setup
    @factory = FakeClientFactory.new
  end

  def build(**kw)
    Nexo::MCP.stub_client_factory(@factory) { Nexo::MCP.build(**kw) }
  end

  def test_static_token_becomes_bearer_header
    build(name: :gmail, transport: :http, url: "https://x", token: "T123")

    cfg = @factory.config
    assert_equal "Bearer T123", cfg[:headers]["Authorization"]
    refute cfg.key?(:token), "token: must be stripped from the config handed to the client"
  end

  def test_static_token_preserves_caller_headers_and_wins_on_authorization
    build(
      name: :gmail, transport: :http, url: "https://x",
      headers: {"X-Trace" => "abc", "Authorization" => "stale"},
      token: "T123"
    )

    cfg = @factory.config
    assert_equal "abc", cfg[:headers]["X-Trace"], "caller's other headers are preserved"
    assert_equal "Bearer T123", cfg[:headers]["Authorization"], "Nexo's Authorization wins"
  end

  def test_callable_token_is_resolved_once_at_build
    calls = 0
    build(name: :gmail, transport: :http, url: "https://x", token: lambda {
      calls += 1
      "T#{calls}"
    })

    # Construction-only header snapshot (Group 0) => resolved exactly once per build.
    assert_equal "Bearer T1", @factory.config[:headers]["Authorization"]
    assert_equal 1, calls
  end

  def test_token_injection_applies_to_sse_and_streamable_transports
    %i[sse streamable].each do |transport|
      build(name: :gmail, transport: transport, url: "https://x", token: "TOK")
      assert_equal "Bearer TOK", @factory.config[:headers]["Authorization"],
        "#{transport} passes through config: so the same injection applies"
      assert_equal transport, @factory.transport
    end
  end

  def test_no_token_leaves_http_config_untouched
    build(name: :gmail, transport: :http, url: "https://x")
    refute @factory.config.key?(:headers), "absent token: adds no headers key"
  end

  def test_no_token_leaves_stdio_config_untouched
    build(name: :fs, transport: :stdio, command: "npx", args: %w[-y srv])

    cfg = @factory.config
    refute cfg.key?(:headers), "the stdio path is byte-for-byte unchanged"
    assert_equal "npx", cfg[:command]
    assert_equal %w[-y srv], cfg[:args]
  end
end
