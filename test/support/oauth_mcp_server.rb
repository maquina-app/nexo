# frozen_string_literal: true

require "digest"
require "json"
require "securerandom"
require "socket"
require "uri"

# A real HTTP server on 127.0.0.1 that is both an OAuth 2.1 authorization server
# and an MCP server protected by it — enough of each for `ruby_llm`'s MCP client
# to run its whole authorization-code flow against, over real sockets:
#
#   * protected-resource and authorization-server metadata
#   * client registration: dynamic (`/register`) or by Client ID Metadata
#     Document (`mode: :cimd`, where the client id is a URL and nothing registers)
#   * `/authorize` with PKCE (S256), answering with a redirect carrying the code
#   * `/token` for the authorization code and for refresh, rotating refresh tokens
#   * `/mcp`: 401 with a `WWW-Authenticate` challenge unless the bearer token is
#     live; otherwise `initialize`, tools, resources, prompts, and two tools that
#     answer with a task (`slow` finishes on its second check, `stuck` never)
#
# No web framework and no gem: a TCPServer and a thread. It records what it saw
# (`registrations`, `refreshes`, `calls`) so a test can assert on the server's
# side of the conversation.
class OauthMcpServer
  attr_reader :port, :registrations, :refreshes, :calls, :token_requests, :answers, :cancelled_tasks

  # `expires_in:` is what the token endpoint reports; `ruby_llm` refreshes a
  # token within a minute of its expiry, so a small value forces a refresh on
  # the next request.
  def initialize(mode: :dcr, expires_in: 3600)
    @mode = mode
    @expires_in = expires_in
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @clients = {}
    @codes = {}
    @access = {}
    @refresh = {}
    @registrations = []
    @token_requests = []
    @refreshes = 0
    @calls = []
    @answers = []
    @tasks = {}
    @cancelled_tasks = []
    @lock = Mutex.new
    @thread = Thread.new { serve }
    @thread.report_on_exception = false
  end

  def origin = "http://127.0.0.1:#{@port}"

  def url = "#{origin}/mcp"

  # Forgets every access token, as a server-side revocation would.
  def revoke_access_tokens! = @lock.synchronize { @access.clear }

  # Registers a client by hand, standing in for a fetched metadata document.
  def trust_client(client_id, redirect_uris:)
    @lock.synchronize { @clients[client_id] = {redirect_uris: redirect_uris} }
  end

  def stop
    @server.close
    @thread.kill
  rescue IOError
    nil
  end

  private

  def serve
    loop do
      socket = @server.accept
      Thread.new(socket) do |client|
        handle(client)
      rescue => e
        respond(client, 500, {error: "#{e.class}: #{e.message}"})
      ensure
        client.close unless client.closed?
      end
    end
  rescue IOError, Errno::EBADF
    nil
  end

  def handle(client)
    request_line = client.gets or return
    verb, target, = request_line.split
    headers = {}
    while (line = client.gets) && line != "\r\n"
      name, value = line.split(":", 2)
      headers[name.downcase] = value.to_s.strip
    end
    body = headers["content-length"] ? client.read(headers["content-length"].to_i) : ""
    uri = URI(target)
    route(client, verb, uri.path, URI.decode_www_form(uri.query.to_s).to_h, headers, body)
  end

  def route(client, verb, path, query, headers, body)
    case [verb, path]
    when ["GET", "/.well-known/oauth-protected-resource/mcp"], ["GET", "/.well-known/oauth-protected-resource"]
      respond(client, 200, {resource: url, authorization_servers: [origin], scopes_supported: %w[read]})
    when ["GET", "/.well-known/oauth-authorization-server"]
      respond(client, 200, server_metadata)
    when ["POST", "/register"] then register(client, JSON.parse(body))
    when ["GET", "/authorize"] then authorize(client, query)
    when ["POST", "/token"] then token(client, URI.decode_www_form(body).to_h)
    when ["POST", "/mcp"] then mcp(client, headers, JSON.parse(body))
    else respond(client, 404, {error: "not found: #{verb} #{path}"})
    end
  end

  def server_metadata
    metadata = {
      issuer: origin, authorization_endpoint: "#{origin}/authorize", token_endpoint: "#{origin}/token",
      response_types_supported: %w[code], grant_types_supported: %w[authorization_code refresh_token],
      code_challenge_methods_supported: %w[S256], token_endpoint_auth_methods_supported: %w[none],
      scopes_supported: %w[read], authorization_response_iss_parameter_supported: true
    }
    if @mode == :cimd
      metadata.merge(client_id_metadata_document_supported: true)
    else
      metadata.merge(registration_endpoint: "#{origin}/register")
    end
  end

  def register(client, document)
    return respond(client, 404, {error: "this server does not register clients"}) if @mode == :cimd

    client_id = "client-#{SecureRandom.hex(4)}"
    @lock.synchronize do
      @registrations << document
      @clients[client_id] = {redirect_uris: document["redirect_uris"]}
    end
    respond(client, 201, document.merge("client_id" => client_id))
  end

  def authorize(client, query)
    known = @lock.synchronize { @clients[query["client_id"]] }
    return respond(client, 400, {error: "unknown client"}) unless known
    return respond(client, 400, {error: "redirect_uri not registered"}) unless known[:redirect_uris].include?(query["redirect_uri"])
    return respond(client, 400, {error: "PKCE S256 required"}) unless query["code_challenge_method"] == "S256"

    code = SecureRandom.hex(8)
    @lock.synchronize { @codes[code] = query }
    callback = URI(query["redirect_uri"])
    callback.query = URI.encode_www_form(code: code, state: query["state"], iss: origin)
    respond(client, 302, {}, "Location" => callback.to_s)
  end

  def token(client, form)
    @lock.synchronize { @token_requests << form.except("code", "code_verifier", "refresh_token") }
    case form["grant_type"]
    when "authorization_code" then exchange_code(client, form)
    when "refresh_token" then exchange_refresh(client, form)
    else respond(client, 400, {error: "unsupported_grant_type"})
    end
  end

  def exchange_code(client, form)
    granted = @lock.synchronize { @codes.delete(form["code"]) }
    return respond(client, 400, {error: "invalid_grant"}) unless granted
    return respond(client, 400, {error: "invalid_grant", error_description: "redirect_uri"}) unless granted["redirect_uri"] == form["redirect_uri"]

    challenge = [Digest::SHA256.digest(form["code_verifier"].to_s)].pack("m0").tr("+/", "-_").delete("=")
    return respond(client, 400, {error: "invalid_grant", error_description: "PKCE"}) unless challenge == granted["code_challenge"]

    respond(client, 200, issue(granted["client_id"]))
  end

  def exchange_refresh(client, form)
    client_id = @lock.synchronize { @refresh.delete(form["refresh_token"]) }
    return respond(client, 400, {error: "invalid_grant"}) unless client_id

    @lock.synchronize { @refreshes += 1 }
    respond(client, 200, issue(client_id))
  end

  def issue(client_id)
    access = "access-#{SecureRandom.hex(8)}"
    refresh = "refresh-#{SecureRandom.hex(8)}"
    @lock.synchronize do
      @access[access] = client_id
      @refresh[refresh] = client_id
    end
    {access_token: access, token_type: "Bearer", expires_in: @expires_in, refresh_token: refresh, scope: "read"}
  end

  def mcp(client, headers, message)
    token = headers["authorization"].to_s[/\ABearer (.+)\z/, 1]
    client_id = @lock.synchronize { @access[token] }
    unless client_id
      challenge = %(Bearer scope="read", resource_metadata="#{origin}/.well-known/oauth-protected-resource/mcp")
      return respond(client, 401, {error: "unauthorized"}, "WWW-Authenticate" => challenge)
    end

    @lock.synchronize { @calls << message["method"] }
    return respond(client, 202, nil) unless message.key?("id")

    if message["method"] == "tools/call" && message.dig("params", "name") == "publish"
      challenge = %(Bearer error="insufficient_scope", scope="write", error_description="Additional scopes required: write")
      return respond(client, 403, {error: "insufficient_scope"}, "WWW-Authenticate" => challenge)
    end

    respond(client, 200, {jsonrpc: "2.0", id: message["id"], result: result_for(message, client_id)})
  end

  def result_for(message, client_id)
    case message["method"]
    when "initialize"
      {protocolVersion: message.dig("params", "protocolVersion"), capabilities: {tools: {}, resources: {}, prompts: {}, completions: {}},
       serverInfo: {name: "nexo-test", version: "1"}}
    when "tools/list"
      {tools: [
        {name: "whoami", description: "Says which client is calling", inputSchema: {type: "object", properties: {}}},
        {name: "publish", description: "Needs the write scope", inputSchema: {type: "object", properties: {}}},
        {name: "book", description: "Books a seat, after asking which", inputSchema: {type: "object", properties: {}}},
        {name: "slow", description: "Answers later, as a task", inputSchema: {type: "object", properties: {}}},
        {name: "stuck", description: "A task that never finishes", inputSchema: {type: "object", properties: {}}}
      ]}
    when "tools/call" then call_result(message["params"], client_id)
    when "resources/list"
      {resources: [{uri: "note://welcome", name: "welcome", mimeType: "text/plain"}]}
    when "resources/read"
      uri = message.dig("params", "uri")
      {contents: [{uri: uri, mimeType: "text/plain", text: "contents of #{uri}"}]}
    when "prompts/list"
      {prompts: [{name: "review", description: "Reviews a change",
                  arguments: [{name: "code", description: "The diff", required: true}]}]}
    when "prompts/get"
      code = message.dig("params", "arguments", "code")
      {description: "Reviews a change", messages: [
        {role: "user", content: {type: "text", text: "Review this change carefully:\n#{code}"}}
      ]}
    when "resources/templates/list"
      {resourceTemplates: [{uriTemplate: "note://{name}", name: "note", mimeType: "text/plain"}]}
    when "completion/complete"
      typed = message.dig("params", "argument", "value").to_s
      {completion: {values: %w[ruby rust python].select { |word| word.start_with?(typed) }}}
    when "tasks/get" then task_state(message.dig("params", "taskId"))
    when "tasks/cancel"
      id = message.dig("params", "taskId")
      @lock.synchronize { @cancelled_tasks << id }
      {taskId: id, status: "cancelled"}
    else {}
    end
  end

  # A task finishes on its second check; `stuck` never does.
  def task_state(id)
    task = @lock.synchronize { @tasks[id].tap { |entry| entry[:polls] += 1 } }
    if task[:name] == "slow" && task[:polls] >= 2
      return {taskId: id, status: "completed", result: {content: [{type: "text", text: "slow work finished"}]}}
    end

    {taskId: id, status: "working", statusMessage: "check #{task[:polls]}", pollIntervalMs: 10}
  end

  # `book` asks the person a question before it answers (MCP elicitation): the
  # first call returns an input request, the second carries the response.
  def call_result(params, client_id)
    if %w[slow stuck].include?(params["name"])
      id = "task-#{SecureRandom.hex(3)}"
      @lock.synchronize { @tasks[id] = {name: params["name"], polls: 0} }
      return {resultType: "task", taskId: id, status: "working", pollIntervalMs: 10}
    end
    return {content: [{type: "text", text: "you are #{client_id}"}]} unless params["name"] == "book"

    answer = params.dig("inputResponses", "seat")
    if answer.nil?
      return {resultType: "input_required", requestState: "state-1", inputRequests: {
        seat: {method: "elicitation/create", params: {
          message: "Window or aisle?",
          requestedSchema: {type: "object", properties: {seat: {type: "string"}}, required: ["seat"]}
        }}
      }}
    end

    @lock.synchronize { @answers << answer }
    {content: [{type: "text", text: "booked: #{answer.to_json}"}]}
  end

  def respond(client, status, payload, extra = {})
    body = payload.nil? ? "" : JSON.generate(payload)
    reason = {200 => "OK", 201 => "Created", 202 => "Accepted", 302 => "Found", 400 => "Bad Request",
              401 => "Unauthorized", 403 => "Forbidden", 404 => "Not Found", 500 => "Internal Server Error"}.fetch(status, "OK")
    head = ["HTTP/1.1 #{status} #{reason}", "Content-Type: application/json", "Content-Length: #{body.bytesize}",
      "Connection: close", *extra.map { |name, value| "#{name}: #{value}" }]
    client.write("#{head.join("\r\n")}\r\n\r\n#{body}")
  end
end
