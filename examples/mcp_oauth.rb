# frozen_string_literal: true

# Signs in to an OAuth-protected MCP server from a terminal, lists its tools and
# makes one read-only call — the whole flow against a real server.
#
#   NEXO_MCP_URL=https://getliminal.app/mcp \
#   NEXO_MCP_CLIENT_ID=https://example.com/oauth/nexo-client.json \
#   NEXO_MCP_TOOL=list_exhibitions \
#   bundle exec ruby examples/mcp_oauth.rb
#
# * NEXO_MCP_CLIENT_ID is only for a server that takes a Client ID Metadata
#   Document: the https URL of a JSON file you host, whose `redirect_uris`
#   lists http://127.0.0.1:8976/callback. A server that registers clients itself
#   needs nothing.
# * NEXO_MCP_TOOL is the tool to call once signed in; leave it out to only list.
# * NEXO_MCP_STORE_KEY (64 hex characters) encrypts the stored credentials.
# * `forget` as the first argument deletes the stored credentials and exits.
#
# The credentials are kept under ~/.local/state/nexo-example/mcp, so a second
# run does not ask you to sign in again. No model is called: the permission gate
# and the tool are exercised directly.
require "nexo"
require "socket"
require "uri"

URL = ENV.fetch("NEXO_MCP_URL")
PORT = 8976
CALLBACK = "http://127.0.0.1:#{PORT}/callback"

RubyLLM.configure do |config|
  config.mcp_client_id = ENV["NEXO_MCP_CLIENT_ID"] if ENV["NEXO_MCP_CLIENT_ID"]
  config.mcp_client_name = "Nexo example"
  config.mcp_credential_store = Nexo::MCP::CredentialStore.new(
    dir: "~/.local/state/nexo-example/mcp", key: ENV["NEXO_MCP_STORE_KEY"]
  )
end

class Visitor < Nexo::Agent
  model "none" # no model is called in this example
  provider :ollama
  assume_model_exists true
  file_tools :none
  mcp :remote, transport: :http, url: URL, oauth: true
  mcp_allow(*ENV.fetch("NEXO_MCP_TOOL", "").split(","))
end

# Waits for the browser to come back to the loopback callback, once, and returns
# the query parameters it carried.
def wait_for_callback
  server = TCPServer.new("127.0.0.1", PORT)
  client = server.accept
  target = client.gets.to_s.split[1].to_s
  client.write("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nSigned in. You can close this tab.\n")
  client.close
  URI.decode_www_form(URI(target).query.to_s).to_h
ensure
  server&.close
end

agent = Visitor.new(mcp_owner: ENV.fetch("USER", "me"))
remote = agent.mcp_server(:remote)

if ARGV.first == "forget"
  remote.deauthorize
  puts "Forgot the stored credentials for #{URL}."
  exit
end

if remote.authorized?
  puts "Already signed in to #{URL} (stored credentials)."
else
  url = remote.authorization_url(redirect_uri: CALLBACK)
  puts "Opening your browser to sign in. If it does not open, visit:\n  #{url}\n"
  system("open", url) || system("xdg-open", url)
  remote.authorize(wait_for_callback)
  puts "Signed in."
end

tools = remote.tools
puts "#{tools.size} tools: #{tools.map(&:name).sort.join(", ")}"

if (name = ENV["NEXO_MCP_TOOL"])
  gated = agent.chat.tools.fetch(name.to_sym) { abort "#{name} is not offered by the server" }
  result = gated.call
  puts "\n#{name} →"
  puts (result.respond_to?(:text) ? result.text : result).to_s[0, 1200]
end
agent.close
