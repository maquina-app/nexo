# frozen_string_literal: true

require "test_helper"
require "net/http"
require "tmpdir"
require_relative "support/oauth_mcp_server"

# 0.16 — MCP OAuth over real HTTP. The whole authorization-code flow runs through
# ruby_llm's real client against a real server on 127.0.0.1 (OauthMcpServer):
# discovery, client registration, PKCE, the code exchange, bearer requests, token
# refresh, and forgetting the credentials. Only the model's replies are scripted,
# and the test stands in for the browser by following the authorization redirect.
class McpOauthRoundtripTest < Minitest::Test
  CALLBACK = "http://127.0.0.1:9/callback"

  def setup
    skip "scripts the model; skipped in live mode" if ENV["NEXO_LIVE"] == "1"
    WebMock.disable_net_connect!(allow_localhost: true) if defined?(WebMock)
    @previous_store = RubyLLM.config.mcp_credential_store
    @previous_client_id = RubyLLM.config.mcp_client_id
    @dir = Dir.mktmpdir
    @store = Nexo::MCP::CredentialStore.new(dir: @dir, key: Nexo::MCP::CredentialStore.generate_key)
    RubyLLM.config.mcp_credential_store = @store
  end

  def teardown
    @server&.stop
    FileUtils.rm_rf(@dir) if @dir
    return unless defined?(@previous_store)

    RubyLLM.config.mcp_credential_store = @previous_store
    RubyLLM.config.mcp_client_id = @previous_client_id
    WebMock.disable_net_connect! if defined?(WebMock)
  end

  def start(**opts)
    @server = OauthMcpServer.new(**opts)
    url = @server.url
    Class.new(Nexo::Agent) do
      model "gpt-4o-mini"
      mcp :local, transport: :http, url: url, oauth: true
      mcp_allow "whoami"
    end
  end

  # What a person's browser does: open the authorization URL, sign in, and land
  # on the callback with the code. Returns the callback's query parameters.
  def approve_in_browser(authorization_url)
    response = Net::HTTP.get_response(URI(authorization_url))
    assert_equal "302", response.code, response.body
    URI.decode_www_form(URI(response["Location"]).query).to_h
  end

  def authorize(agent)
    server = agent.mcp_server(:local)
    server.authorize(approve_in_browser(server.authorization_url(redirect_uri: CALLBACK)))
    server
  end

  def test_the_whole_flow_from_refusal_to_a_gated_tool_call
    klass = start
    agent = klass.new(mcp_owner: "alice")

    assert_raises(Nexo::AuthorizationRequired) { agent.chat }
    assert_empty @server.calls, "nothing reached the MCP endpoint before authorization"

    server = authorize(agent)

    assert_predicate server, :authorized?
    assert_equal 1, @server.registrations.size
    assert_equal [CALLBACK], @server.registrations.first["redirect_uris"]
    assert_equal "none", @server.registrations.first["token_endpoint_auth_method"]
    assert_equal @server.url, @server.token_requests.first["resource"], "the token is bound to this MCP server"

    assert_kind_of Nexo::MCP::GatedTool, agent.chat.tools[:whoami]
    stub_replies tool_call(:whoami), "done"
    results = []
    agent.prompt("Who am I?") { |type, payload| results << payload if type == :tool_result }

    assert_match(/you are client-/, results.first.text)
    assert_includes @server.calls, "tools/call"
  ensure
    agent&.close
  end

  # Found by this test: a workflow's event log recorded an MCP result as the
  # object's address. It must record the text the server returned.
  def test_a_workflow_drives_the_agent_for_an_owner_and_records_the_result_text
    klass = start
    authorize(klass.new(mcp_owner: "alice")).close
    workflow = Class.new(Nexo::Workflow) do
      agent klass

      def call(payload) = {content: run_agent("Who am I?", mcp_owner: payload["owner"] || payload[:owner]).content}
    end
    stub_replies tool_call(:whoami), "done"

    run = workflow.run(owner: "alice")
    result = run.events.find { |event| event["type"] == "agent_tool_result" }

    assert_equal "done", run.status
    assert_equal true, result["data"]["ok"]
    assert_match(/\Ayou are client-/, result["data"]["content"])

    assert_raises(Nexo::AuthorizationRequired) { workflow.run(owner: "bob") }
  end

  def test_credentials_are_encrypted_on_disk_and_reused_by_a_new_agent_for_the_same_owner
    klass = start
    first = klass.new(mcp_owner: "alice")
    authorize(first)
    first.close

    files = Dir[File.join(@dir, "*.json")]
    refute_empty files
    files.each { |file| refute_match(/access-|refresh-/, File.read(file)) }

    again = klass.new(mcp_owner: "alice")
    assert_includes again.chat.tools.keys, :whoami
    assert_equal 1, @server.registrations.size, "the registered client is reused, not registered again"
    assert_raises(Nexo::AuthorizationRequired) { klass.new(mcp_owner: "bob").chat }
  ensure
    again&.close
  end

  def test_an_expiring_token_is_refreshed_without_asking_the_person_again
    klass = start(expires_in: 30) # inside ruby_llm's refresh window, so every request refreshes first
    agent = klass.new(mcp_owner: "alice")
    authorize(agent)

    assert_includes agent.chat.tools.keys, :whoami
    assert_operator @server.refreshes, :>=, 1
    assert_predicate agent.mcp_server(:local), :authorized?
  ensure
    agent&.close
  end

  def test_deauthorize_forgets_the_owner_and_the_agent_is_refused_again
    klass = start
    agent = klass.new(mcp_owner: "alice")
    authorize(agent).deauthorize

    refute_predicate agent.mcp_server(:local), :authorized?
    assert_raises(Nexo::AuthorizationRequired) { klass.new(mcp_owner: "alice").chat }
  ensure
    agent&.close
  end

  # A server with no registration endpoint, which takes the client's id as the
  # URL of a metadata document (how getliminal.app/mcp works).
  def test_a_server_that_takes_a_client_id_metadata_document
    klass = start(mode: :cimd)
    client_id = "https://example.com/oauth/nexo-client.json"
    RubyLLM.config.mcp_client_id = client_id
    @server.trust_client(client_id, redirect_uris: [CALLBACK])
    agent = klass.new(mcp_owner: "alice")

    authorize(agent)

    assert_empty @server.registrations
    assert_equal client_id, @server.token_requests.first["client_id"]
    assert_includes agent.chat.tools.keys, :whoami
  ensure
    agent&.close
  end

  def test_without_a_client_id_such_a_server_cannot_be_authorized
    klass = start(mode: :cimd)
    RubyLLM.config.mcp_client_id = nil
    agent = klass.new(mcp_owner: "alice")

    error = assert_raises(RubyLLM::MCP::Error) { agent.mcp_server(:local).authorization_url(redirect_uri: CALLBACK) }

    assert_match(/does not register clients/, error.message)
  ensure
    agent&.close
  end

  def test_a_wrong_state_on_the_callback_is_refused
    klass = start
    agent = klass.new(mcp_owner: "alice")
    server = agent.mcp_server(:local)
    params = approve_in_browser(server.authorization_url(redirect_uri: CALLBACK))

    assert_raises(RubyLLM::MCP::Error) { server.authorize(params.merge("state" => "forged")) }
    refute_predicate server, :authorized?
  ensure
    agent&.close
  end
end
