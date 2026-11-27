# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# 0.15 — OAuth for MCP servers. ruby_llm runs the flow; Nexo passes the options
# through the `mcp` macro, supplies the owner, refuses to start an unauthorized
# server, and offers an on-disk credential store.
class McpOauthTest < Minitest::Test
  class FakeClientFactory
    attr_reader :settings

    def mcp(**settings)
      @settings = settings
      :fake_server
    end
  end

  User = Struct.new(:id) do
    def to_gid = "gid://app/User/#{id}"
  end

  def setup
    @factory = FakeClientFactory.new
    @previous_store = RubyLLM.config.mcp_credential_store
  end

  def teardown
    RubyLLM.config.mcp_credential_store = @previous_store
  end

  def build(**kw)
    Nexo::MCP.stub_client_factory(@factory) { Nexo::MCP.build(**kw) }
  end

  # --- the settings handed to ruby_llm ---------------------------------------

  def test_oauth_true_becomes_an_empty_oauth_hash
    build(name: :linear, transport: :http, url: "https://mcp.example.com", oauth: true)

    assert_equal({}, @factory.settings[:oauth])
  end

  def test_oauth_options_pass_through_and_the_owner_is_supplied
    build(name: :slack, transport: :http, url: "https://mcp.example.com", owner: "user-7",
      oauth: {client_id: "id", client_secret: "secret", scopes: %w[read]})

    oauth = @factory.settings[:oauth]
    assert_equal "id", oauth[:client_id]
    assert_equal %w[read], oauth[:scopes]
    assert_equal "user-7", oauth[:owner].call
    refute @factory.settings.key?(:owner), "owner: is Nexo's own option"
  end

  def test_a_record_with_a_global_id_is_an_owner
    user = User.new(7)
    build(name: :linear, transport: :http, url: "https://mcp.example.com", oauth: true, owner: user)

    assert_same user, @factory.settings[:oauth][:owner].call
  end

  def test_an_owner_with_no_stable_identity_is_refused
    error = assert_raises(Nexo::ConfigurationError) do
      build(name: :linear, transport: :http, url: "https://mcp.example.com", oauth: true, owner: Object.new)
    end

    assert_match(/owner must be/, error.message)
  end

  def test_oauth_and_token_cannot_be_combined
    assert_raises(Nexo::ConfigurationError) do
      build(name: :linear, transport: :http, url: "https://mcp.example.com", oauth: true, token: "T")
    end
  end

  def test_oauth_on_a_stdio_server_is_refused
    assert_raises(Nexo::ConfigurationError) do
      build(name: :local, transport: :stdio, command: "server", oauth: true)
    end
  end

  def test_only_the_authorization_code_grant_needs_a_person
    assert Nexo::MCP.user_authorized?(oauth: true)
    assert Nexo::MCP.user_authorized?(oauth: {client_id: "x"})
    refute Nexo::MCP.user_authorized?(oauth: {grant: :client_credentials})
    refute Nexo::MCP.user_authorized?(oauth: {assertion: -> { "jwt" }})
    refute Nexo::MCP.user_authorized?(token: "T")
  end

  # --- against ruby_llm's real MCP class (no network: only the store is read) --

  class Assistant < Nexo::Agent
    model "gpt-4o-mini"
    mcp :linear, transport: :http, url: "https://mcp.example.com/mcp", oauth: true
  end

  def test_an_unauthorized_server_stops_the_agent_before_any_request
    RubyLLM.config.mcp_credential_store = RubyLLM::MCP::OAuth::MemoryStore.new
    agent = Assistant.new(mcp_owner: "user-7")

    error = assert_raises(Nexo::AuthorizationRequired) { agent.chat }

    assert_equal :linear, error.server
    refute_predicate agent.mcp_server(:linear), :authorized?
  end

  def test_credentials_are_found_per_owner_in_the_disk_store
    Dir.mktmpdir do |dir|
      store = Nexo::MCP::CredentialStore.new(dir: dir)
      RubyLLM.config.mcp_credential_store = store
      store.write("user-7@https://mcp.example.com/mcp", {"access_token" => "A"})

      assert_predicate Assistant.new(mcp_owner: "user-7").mcp_server(:linear), :authorized?
      refute_predicate Assistant.new(mcp_owner: "user-8").mcp_server(:linear), :authorized?
    end
  end

  def test_mcp_server_rejects_an_undeclared_name
    assert_raises(Nexo::ConfigurationError) { Assistant.new.mcp_server(:nope) }
  end

  # --- the disk store ---------------------------------------------------------

  def test_the_disk_store_round_trips_and_deletes
    Dir.mktmpdir do |dir|
      store = Nexo::MCP::CredentialStore.new(dir: File.join(dir, "mcp"))
      key = "user-7@https://mcp.example.com/mcp"

      assert_nil store.read(key)
      store.write(key, {"access_token" => "A", "refresh_token" => "R"}, owner: "user-7")
      assert_equal({"access_token" => "A", "refresh_token" => "R"}, store.read(key))

      store.delete(key)
      assert_nil store.read(key)
      assert_nil store.delete(key)
    end
  end

  def test_the_disk_store_keeps_its_files_private_and_its_names_opaque
    Dir.mktmpdir do |dir|
      root = File.join(dir, "mcp")
      store = Nexo::MCP::CredentialStore.new(dir: root)
      store.write("user-7@https://mcp.example.com/mcp", {"access_token" => "A"})
      file = Dir.children(root).first

      assert_equal 0o700, File.stat(root).mode & 0o777
      assert_equal 0o600, File.stat(File.join(root, file)).mode & 0o777
      refute_match(/user|example/, file)
    end
  end

  def test_a_corrupt_file_reads_as_not_authorized
    Dir.mktmpdir do |dir|
      store = Nexo::MCP::CredentialStore.new(dir: dir)
      store.write("k", {"access_token" => "A"})
      File.write(Dir.glob(File.join(dir, "*.json")).first, "{not json")

      assert_nil store.read("k")
    end
  end

  def test_synchronize_runs_the_block_and_returns_its_value
    Dir.mktmpdir do |dir|
      assert_equal 42, Nexo::MCP::CredentialStore.new(dir: dir).synchronize("k") { 42 }
    end
  end
end
