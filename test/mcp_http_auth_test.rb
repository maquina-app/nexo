# frozen_string_literal: true

require "test_helper"

# MCP settings mapping: Nexo's transport-shaped `mcp` macro opts → the keywords
# `RubyLLM.mcp` takes (ruby_llm's built-in MCP client).
#
# Subject: Nexo::MCP.build's TRANSFORM (not ruby_llm). A fake factory records the
# exact settings ruby_llm would receive, so the offline suite proves the stdio
# command mapping, the bearer-token handoff, and pass-through without a live server.
#
# VERIFIED (ruby_llm 2.2.3): an HTTP server takes `url:`/`headers:`/`bearer_token:`;
# a stdio server takes `command:` (argv) plus `env:`/`directory:`. A Proc
# `bearer_token` is read again for every request.
class McpHttpAuthTest < Minitest::Test
  # Records the settings ruby_llm would receive — a real recording object at the
  # boundary, swapped in via Nexo::MCP.stub_client_factory.
  class FakeClientFactory
    attr_reader :settings

    def mcp(**settings)
      @settings = settings
      :fake_server
    end
  end

  def setup
    @factory = FakeClientFactory.new
  end

  def build(**kw)
    Nexo::MCP.stub_client_factory(@factory) { Nexo::MCP.build(**kw) }
  end

  def test_build_returns_what_the_factory_built
    assert_equal :fake_server, build(name: :gmail, transport: :http, url: "https://x")
  end

  def test_static_token_becomes_the_bearer_token
    build(name: :gmail, transport: :http, url: "https://x", token: "T123")

    assert_equal "T123", @factory.settings[:bearer_token]
    assert_equal "https://x", @factory.settings[:url]
    assert_equal "gmail", @factory.settings[:name]
    refute @factory.settings.key?(:token), "token: is Nexo's own option and is never handed off"
    refute @factory.settings.key?(:transport), "the transport symbol is Nexo's own and is never handed off"
  end

  def test_caller_headers_are_preserved_alongside_the_token
    build(
      name: :gmail, transport: :http, url: "https://x",
      headers: {"X-Trace" => "abc"},
      token: "T123"
    )

    assert_equal({"X-Trace" => "abc"}, @factory.settings[:headers], "caller's headers pass through untouched")
    assert_equal "T123", @factory.settings[:bearer_token]
  end

  # ruby_llm reads a Proc bearer token again for each request, so a rotated token
  # is picked up without reconnecting. Nexo must not resolve it at build time.
  def test_callable_token_is_handed_off_unresolved_and_reads_fresh_each_time
    calls = 0
    build(name: :gmail, transport: :http, url: "https://x", token: lambda {
      calls += 1
      "T#{calls}"
    })

    bearer = @factory.settings[:bearer_token]
    assert_kind_of Proc, bearer
    assert_equal 0, calls, "the token is not resolved at build time"
    assert_equal "T1", bearer.call
    assert_equal "T2", bearer.call
  end

  def test_non_proc_callable_token_is_wrapped_in_a_proc
    provider = Struct.new(:value) { def call = value }.new("TOK")

    build(name: :gmail, transport: :http, url: "https://x", token: provider)

    bearer = @factory.settings[:bearer_token]
    assert_kind_of Proc, bearer, "ruby_llm only re-reads a Proc, so other callables are wrapped"
    assert_equal "TOK", bearer.call
  end

  def test_token_applies_to_sse_and_streamable_transports
    %i[sse streamable].each do |transport|
      build(name: :gmail, transport: transport, url: "https://x", token: "TOK")
      assert_equal "TOK", @factory.settings[:bearer_token], "#{transport} is an HTTP transport"
    end
  end

  def test_no_token_adds_no_bearer_token
    build(name: :gmail, transport: :http, url: "https://x")

    refute @factory.settings.key?(:bearer_token)
    refute @factory.settings.key?(:headers)
  end

  def test_stdio_command_and_args_become_one_argv
    build(name: :fs, transport: :stdio, command: "npx", args: %w[-y srv])

    settings = @factory.settings
    assert_equal %w[npx -y srv], settings[:command]
    refute settings.key?(:args), "args: is folded into command:"
    refute settings.key?(:bearer_token)
    assert_equal "fs", settings[:name]
  end

  def test_stdio_env_and_directory_pass_through
    build(name: :fs, transport: :stdio, command: "srv", env: {API_KEY: "k"}, directory: "/tmp")

    assert_equal({API_KEY: "k"}, @factory.settings[:env])
    assert_equal "/tmp", @factory.settings[:directory]
  end

  def test_stdio_without_a_command_is_a_configuration_error
    error = assert_raises(Nexo::ConfigurationError) { build(name: :fs, transport: :stdio) }
    assert_match(/command/, error.message)
  end

  def test_unknown_transport_is_a_configuration_error
    error = assert_raises(Nexo::ConfigurationError) { build(name: :fs, transport: :carrier_pigeon, url: "https://x") }
    assert_match(/unknown transport/, error.message)
  end

  # Against the real ruby_llm factory: a setting it does not know is refused, and
  # Nexo reports it as a configuration error naming the server.
  def test_unknown_setting_is_refused_by_ruby_llm_as_a_configuration_error
    error = assert_raises(Nexo::ConfigurationError) do
      Nexo::MCP.build(name: :fs, transport: :stdio, command: "srv", nonsense: 1)
    end
    assert_match(/mcp :fs/, error.message)
  end

  # Against the real ruby_llm factory: building connects to nothing.
  def test_real_build_returns_a_ruby_llm_mcp_server_without_connecting
    server = Nexo::MCP.build(name: :fs, transport: :stdio, command: "definitely-not-a-real-binary", args: %w[x])

    assert_kind_of RubyLLM::MCP, server
    assert_equal "fs", server.name
    assert_respond_to server, :tools
    assert_respond_to server, :close
  end
end
