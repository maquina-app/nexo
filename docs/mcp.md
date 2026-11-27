# MCP data sources
Attach one or more MCP servers with a single `mcp` macro — every call gated by a second, fail-closed permission axis.

An **MCP server** exposes tools to a model over the [Model Context
Protocol](https://modelcontextprotocol.io) — Gmail, a filesystem, a fetch endpoint,
Drive, and so on. Nexo does not implement MCP; it composes the MCP client built into
[`ruby_llm`](https://rubyllm.com/mcp/) (core since 2.1) so you attach one or more
servers with a single `mcp` macro and no client wiring — and no extra gem. Because a server is reached
*through the protocol* (never a vendor SDK), the behavior is identical on Anthropic, a
local model, or anything else `ruby_llm` supports.

```ruby
require "nexo"

class InboxDigest < Nexo::Agent
  model       ENV.fetch("NEXO_MODEL")   # any ruby_llm model — never a hardcoded vendor default
  permissions :read_only
  mcp :gmail, transport: :stdio, command: "npx", args: %w[-y @modelcontextprotocol/server-gmail]
  mcp :fs,    transport: :stdio, command: "npx", args: %w[-y @modelcontextprotocol/server-filesystem /data]
  mcp :fetch, transport: :sse,   url: "http://localhost:8080/sse"
  mcp_allow %w[search_threads get_thread]
end
```

Each `mcp` line accumulates a server declaration. `name` and `transport` map onto the
client's `name:`/`transport_type:`; every other keyword is passed through verbatim as the
server's `config:` — `command:`/`args:` for `:stdio`, `url:` for `:sse`. The server's tools
are attached to the chat after the sandbox tools and skills, and fire the same
`before_tool_call`/`after_tool_result` observability callbacks, so MCP calls appear in a
run's event log automatically.

## Connecting to a server — pick your case

Four questions decide how a server is declared: where it runs, whether it needs a
credential, whose credential that is, and how the server learns who your application is.

| The server… | Declare it with | Section |
|---|---|---|
| is a program on this machine | `transport: :stdio, command:` | [Stdio](#stdio-servers-environment-and-stderr) |
| is a URL and needs no credential | `transport: :http, url:` | below |
| is a URL and takes one API key or a token you already have | `transport: :http, url:, token:` | [Bearer token](#http-servers--a-bearer-token) |
| is a URL and signs each user in (OAuth) | `transport: :http, url:, oauth:` | [OAuth](#http-servers--oauth) |

Then, in every case, list the tools the agent may call with `mcp_allow` — nothing is callable
until you do — and call `agent.close` when you are done with a long-lived agent.

### 1. A local program

```ruby
class Notes < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  mcp :files, transport: :stdio, command: "npx", args: %w[-y @modelcontextprotocol/server-filesystem /data],
              env: {LOG_LEVEL: "error"}
  mcp_allow "read_text_file", "list_directory"
  file_tools :none   # this server's tools are named like Nexo's file tools; see the Tools guide
end
```

The process starts on the first prompt and gets a short environment, so pass what it needs
with `env:`.

### 2. A URL with a key or a token

```ruby
class Tracker < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  mcp :issues, transport: :http, url: "https://mcp.example.com/mcp", token: ENV.fetch("ISSUES_API_KEY")
  mcp_allow "list_issues", "get_issue"
end
```

`token:` is also where a per-user token goes when your application already runs the sign-in
itself: `token: -> { Current.user.issues_access_token }` is read again for every request.

### 3. A URL that signs each user in

Use this when the server speaks OAuth and you want `ruby_llm` to run the flow. There are four
pieces, and a host application writes all four once.

**a. Declare the server and where its tokens are kept.**

```ruby
class Assistant < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  mcp :linear, transport: :http, url: "https://mcp.linear.app/mcp", oauth: true
  mcp_allow "list_issues"
end

# config/initializers/nexo.rb — Rails with `rails g ruby_llm:install` needs nothing here:
# ruby_llm keeps the tokens in its own encrypted table. Anywhere else:
RubyLLM.configure do |config|
  config.mcp_credential_store = Nexo::MCP::CredentialStore.new(
    dir: "/var/lib/my-app/mcp", key: ENV.fetch("MCP_STORE_KEY")
  )
end
```

**b. Say who your application is.** Try `oauth: true` first: most servers register a client
by themselves. If the server answers "does not register clients", it wants one of the other
two — a client you registered by hand (`oauth: {client_id:, client_secret:}`), or a Client ID
Metadata Document your application serves (see [below](#http-servers--oauth)).

**c. Send the user to sign in, and take the callback.**

```ruby
class McpConnectionsController < ApplicationController
  def new       # GET /mcp/linear/connect
    server = Assistant.new(mcp_owner: Current.user).mcp_server(:linear)
    redirect_to server.authorization_url(redirect_uri: mcp_callback_url), allow_other_host: true
  end

  def callback  # GET /mcp/callback?code=…&state=…
    Assistant.new(mcp_owner: Current.user).mcp_server(:linear).authorize(params.permit!.to_h)
    redirect_to root_path, notice: "Linear is connected."
  rescue RubyLLM::MCP::Error => e
    redirect_to root_path, alert: "Linear was not connected: #{e.message}"
  end

  def destroy   # DELETE /mcp/linear
    Assistant.new(mcp_owner: Current.user).mcp_server(:linear).deauthorize
    redirect_to root_path, notice: "Linear is disconnected."
  end
end
```

**d. Use the agent, and send a user who has not signed in to step c.**

```ruby
agent = Assistant.new(mcp_owner: Current.user)
agent.prompt("What is assigned to me?")
rescue Nexo::AuthorizationRequired => e
  redirect_to mcp_connect_path(e.server)   # raised before any request reaches the server
ensure
  agent&.close
```

Tokens are refreshed for you. A user is asked again only after `deauthorize`, or when the
server revokes the grant.

A terminal program does the same with a one-shot listener on `127.0.0.1` in place of the
controller: [`examples/mcp_oauth.rb`](https://github.com/maquina-app/nexo/blob/main/examples/mcp_oauth.rb).

### When it does not connect

| What you see | Cause |
|---|---|
| The model says it has no such tool | The tool is not in `mcp_allow` (under `:read_only` an unlisted tool is not attached). |
| `Nexo::AuthorizationRequired` | This owner has not signed in to that server yet. |
| `… does not register clients` | The server wants a client id or a Client ID Metadata Document. |
| `Nexo::ConfigurationError` naming `read_file` or another tool | The server's tool has the name of one of the agent's own; declare `file_tools :none` or drop it from `mcp_allow`. |
| `The authorization state does not match` | The callback did not come from the sign-in you started, or it was used twice. |
| `OAuth endpoints must use HTTPS` | Only a server on `127.0.0.1`/`localhost` may use plain `http`. |
| A stdio server exits at once | It needs a variable that was not passed with `env:`; its stderr is in your terminal. |

## More than tools

**Resources.** A server can offer things to read — files, records, documents — besides tools
to call. Ask for them per server, and allow the two tools that reach them:

```ruby
mcp :docs, transport: :http, url: "https://mcp.example.com/mcp", resources: true
mcp_allow "list_mcp_resources", "read_mcp_resource"
```

`list_mcp_resources` prints server, uri, name and type; `read_mcp_resource` returns a
resource's text, up to 200 KB (a binary one is an error result). Both are on the MCP
permission axis, because the read happens in the server: allowing `read_mcp_resource` lets
the model read **any** resource those servers offer.

**A server that asks the user something.** Some tools stop to ask (MCP calls it elicitation).
`prompt` raises `Nexo::InputRequired` with the questions; a workflow suspends and resumes with
the answers. See [the loop guide](loops.md) and [durable workflows](durable-workflows.md).

**A call refused for want of a scope.** When a server answers that the stored grant lacks a
scope, the call raises `Nexo::AuthorizationRequired` — the same error as "never signed in" —
with the scopes it asked for:

```ruby
rescue Nexo::AuthorizationRequired => e
  e.server   # => :github
  e.scopes   # => ["repo"]      (empty when the user never signed in)
  redirect_to mcp_connect_path(e.server)   # the authorization URL asks for the wider grant
```

**A server with many tools.** `mcp :name, …, defer: true` keeps its tool definitions out of
the model's context until the provider's tool search asks for them.

**Not wrapped by Nexo:** a server's prompts and its long-running tasks. The `ruby_llm` server
object is reachable (`agent.mcp_server(:name).prompts`), but Nexo adds nothing around them and
has not tested them.

## Every MCP tool call is gated — and fails closed

MCP tools obey a **second permission axis**, separate from the sandbox capability axis,
because an MCP tool executes inside the server, outside the sandbox. `mcp_allow` is the
exact-match allow-list threaded into the agent's permissions:

| Mode | MCP tool behavior |
|---|---|
| `:read_only` (default) | allow **only** tool names listed in `mcp_allow`; everything else is denied |
| `:ask` | call `on_ask.call(:mcp, {tool:, args:})`; a truthy return allows, else deny |
| `:approve` | names in `mcp_allow` are pre-approved; any other tool needs a human decision — undecided **suspends the run** (`Nexo::ApprovalRequired`), `approved: true` allows, `approved: false` denies (the durable sibling of `:ask`) |

| `:auto` | allow every MCP tool |

Under `:read_only` an MCP tool that is not in `mcp_allow` is not attached at all (0.14): the
model never sees a tool it could not call. Under `:approve` each call is decided on its own —
the tool name and its arguments identify it — so approving one `send_email` does not approve
the next.

`mcp_allow` defaults to `[]`, so attaching a powerful server under `:read_only` with no
allow-list denies **every** tool — a misconfigured agent fails closed, not open. A denied
call returns `{ error: … }` to the model (recoverable) and never raises into the loop —
identical to the sandbox tools. Escalation (`:auto`, a populated `mcp_allow`, or `:ask`
with a real `on_ask`) is always explicit in your code. Matching is exact tool-name only —
no globs or regexes.

**Two caveats — read before attaching a server:**

1. **MCP tool *effects* are not sandboxed.** The gate covers the authority to *invoke* a
   tool; the tool then runs in the MCP server, outside Nexo's sandbox. Nexo cannot
   constrain what that server does with a call it is authorized to make — attaching a write
   server and allowing a write tool means real writes happen. Gate deliberately, and prefer
   `:read_only` with a tight `mcp_allow`.
2. **Connection lifecycle.** Servers are built once and **memoized on the agent instance**,
   reused across prompts (a server connects on its first request and stays connected). A
   long-lived agent holding stdio/HTTP servers should call `Agent#close` when done to tear
   the connections down:

   ```ruby
   agent = InboxDigest.new
   agent.prompt("Summarize invoices from this week")
   agent.prompt("Any follow-ups needed?")   # reuses the same live MCP connections
   agent.close                              # stops every attached server
   ```

## Stdio servers: environment and stderr

A `:stdio` server is a process Nexo's host starts. Two things about it come from
`ruby_llm` and are worth knowing:

- **It gets a short environment.** The process inherits only a small set of safe variables
  (`PATH`, `HOME`, `LANG`, `TMPDIR`, `USER`, and a few more) — not your application's
  secrets. Pass anything else the server needs with `env:`:

  ```ruby
  mcp :github, transport: :stdio, command: "github-mcp", env: {GITHUB_TOKEN: ENV.fetch("GITHUB_TOKEN")}
  ```

- **Its stderr is your process's stderr.** A chatty server prints straight into your
  terminal or log. To drop it, wrap the command:
  `command: "sh", args: ["-c", 'exec "$0" 2>/dev/null', "apple-mail-mcp"]`.

`command:` takes a String or an argv Array, `args:` is appended to it, and `directory:`
sets the process's working directory.

## HTTP servers + a bearer `token:`

Beyond `:stdio`, Nexo attaches a server over HTTP — `transport: :http`, `:sse`, or
`:streamable` (all three are "a URL"; `ruby_llm` speaks Streamable HTTP and falls back for
older servers by itself). For an authenticated hosted server (Gmail, Drive, …) add a
`token:` — a static bearer `String`, or a **callable** that returns one:

```ruby
class InboxTriageHTTP < Nexo::Agent
  model       ENV.fetch("NEXO_MODEL")
  permissions :read_only

  # Hosted Gmail MCP server over HTTP; the host supplies the OAuth access token.
  mcp :gmail,
    transport: :http,
    url:       ENV.fetch("GMAIL_MCP_URL"),
    token:     -> { Current.user.gmail_access_token }   # read again for each request

  # READ tools only — the unchanged gate denies send/trash/modify.
  mcp_allow %w[search_threads get_thread list_messages get_message list_labels]
end
```

A static token (`token: ENV.fetch("GMAIL_TOKEN")`) is equally valid. Under the hood
Nexo hands the token to `ruby_llm` as the server's bearer token:

```ruby
RubyLLM.mcp(name: "gmail", url: "https://…", bearer_token: -> { … })
```

`ruby_llm` sends it as `Authorization: Bearer <token>`. Any `headers:` you pass are sent
too; the bearer token wins the `Authorization` header.

**A callable token is read again for every request.** When a token rotates, the next
request carries the new value — no reconnect needed. (Under `ruby_llm` 1.x a callable was
resolved once per connection and a rotation needed `agent.close`; that caveat is gone.)

**With `token:` the sign-in is yours.** Nexo performs no authorization-code exchange and no
token refresh for a `token:` server — that is your app or an OAuth library; to have
`ruby_llm` run the flow, use [`oauth:`](#http-servers--oauth) instead. The token
is never logged, persisted, placed in a URL/query string, or emitted in an event (the
event path carries only tool `name`/`args` and return values — never connection config).

**The gate is unchanged.** An HTTP server's tools are gated exactly like `:stdio`
tools: denied under `:read_only` until the exact name is in `mcp_allow` (default `[]` ⇒
deny-all). Attaching an authenticated server adds no permission surface.

**The token is a live credential.** Even gated, an authorized MCP call runs its effect
server-side — a leaked bearer is a real compromise. Nexo keeps it out of logs, events,
persisted `WorkflowRun` records, and URLs; your host code must do the same. Nexo does
not police `ruby_llm`'s own debug logging (`RUBYLLM_DEBUG`) — that boundary is yours.

> **Upgrading from 0.12:** remove `gem "ruby_llm-mcp"` from your Gemfile. It defines the
> same `RubyLLM::MCP` constant as `ruby_llm` 2.x and the two cannot be bundled together.
> The `mcp` macro and `mcp_allow` are unchanged.


## HTTP servers + OAuth

For a server that signs users in — Linear, Slack, Google, your own — pass `oauth:` in place
of `token:`. `ruby_llm` runs the whole flow (discovery, client registration, PKCE, token
refresh, DPoP). Nexo adds three things: whose credentials are used, a clear stop before an
unauthorized server is touched, and somewhere to keep the tokens outside Rails.

```ruby
class Assistant < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  mcp :linear, transport: :http, url: "https://mcp.linear.app/mcp", oauth: true
  mcp :slack,  transport: :http, url: "https://mcp.slack.com/mcp",
               oauth: {client_id: ENV["SLACK_CLIENT_ID"], client_secret: ENV["SLACK_CLIENT_SECRET"]}
  mcp_allow "list_issues", "search_messages"
end
```

`oauth:` is `true` or a Hash of the options `RubyLLM::MCP.oauth` takes: `client_id:`,
`client_secret:`, `scopes:`, `grant:`, `private_key:`, `assertion:`, `identity_provider:`,
`authorization_params:`.

**Whose credentials.** Pass the owner when you build the agent:

```ruby
agent = Assistant.new(mcp_owner: current_user)
```

Credentials are stored per owner and server. The owner must be a record with a GlobalID, or a
String, Symbol or Integer you keep stable. Anything else is refused, because it would be
filed under a name that changes every run.

**Authorizing.** `agent.mcp_server(name)` is the `ruby_llm` server object. Send the user
to its authorization URL and hand the callback's parameters back:

```ruby
linear = agent.mcp_server(:linear)
redirect_to linear.authorization_url(redirect_uri: mcp_callback_url), allow_other_host: true unless linear.authorized?

# in the callback action
Assistant.new(mcp_owner: current_user).mcp_server(:linear).authorize(params)
```

`#deauthorize` forgets the owner's credentials.

**From a workflow.** `run_agent` takes the owner too (0.16). Pass an id that is in the run's
payload, so a resumed or retried run finds the same owner:

```ruby
def call(payload)
  run_agent("Summarise my open issues", mcp_owner: payload[:user_id])
end
```

**How the server learns who the client is.** Three ways, chosen by what the server supports:

- *It registers clients itself* (dynamic client registration): nothing to configure.
- *You registered a client by hand*: pass `oauth: {client_id: "...", client_secret: "..."}`.
- *It takes a Client ID Metadata Document* — the client id is the `https` URL of a small JSON
  file you host, listing your name and redirect URIs. Set it once for the process:

  ```ruby
  RubyLLM.configure { |config| config.mcp_client_id = "https://example.com/oauth/client.json" }
  ```

  ```json
  {
    "client_id": "https://example.com/oauth/client.json",
    "client_name": "My App",
    "redirect_uris": ["https://example.com/mcp/callback"],
    "grant_types": ["authorization_code", "refresh_token"],
    "response_types": ["code"],
    "token_endpoint_auth_method": "none"
  }
  ```

  The application that signs users in is the one that serves this file — it is that
  application's identity, and its `redirect_uris` are that application's callback URLs. In
  Rails it is one route:

  ```ruby
  # config/routes.rb
  get "oauth/client.json", to: "oauth_clients#show"

  # app/controllers/oauth_clients_controller.rb
  def show
    render json: {
      client_id: oauth_client_url(format: :json), client_name: "My App",
      redirect_uris: [mcp_callback_url], grant_types: %w[authorization_code refresh_token],
      response_types: %w[code], token_endpoint_auth_method: "none"
    }
  end
  ```

  The server fetches it itself, so it must be reachable over `https`, answer with a JSON
  content type, and carry a `client_id` equal to its own URL. A server that supports only
  this and gets no `mcp_client_id` fails with "does not register clients".

**Before it is authorized.** Building the chat raises `Nexo::AuthorizationRequired`, whose
`#server` names the one to authorize. It is raised before any request is made, from the
credential store alone. Servers on the `client_credentials` or JWT-bearer grant need no
person and fetch their own token on first use.

**Where the tokens live.** `ruby_llm` keeps them in memory by default and in an encrypted
table under Rails (`rails g ruby_llm:install`). For a host with neither, Nexo ships a store
on disk:

```ruby
RubyLLM.configure do |config|
  config.mcp_credential_store = Nexo::MCP::CredentialStore.new(dir: "~/.local/state/my-app/mcp")
end
```

⚠️ These files hold live access and refresh tokens. The directory is created `0700` and each
file `0600`. Without a key they are plain JSON, which is the protection an SSH key has and
no more: acceptable for a personal CLI, wrong for a shared, synced or backed-up directory.
Pass a `key:` and every file is encrypted with AES-256-GCM (0.16):

```ruby
Nexo::MCP::CredentialStore.generate_key   # => 64 hex characters; do this once
Nexo::MCP::CredentialStore.new(dir: "/var/lib/my-app/mcp", key: ENV.fetch("MCP_STORE_KEY"))
```

Keep the key out of the directory (an environment variable, a keychain, a secrets manager).
A file that does not decrypt — a wrong key, a tampered file, a file copied from another
owner — reads as "not authorized", never as an error. Plain files written before a key was
set are still read, and are encrypted the next time they are written.

The permission gate is unchanged by any of this: an OAuth server's tools are still denied
unless `mcp_allow` lists them, and under `:approve` each call still asks.

> **Verified over real HTTP (0.16).** `test/mcp_oauth_roundtrip_test.rb` runs the whole flow
> through `ruby_llm`'s client against an authorization server and MCP server on `127.0.0.1`:
> discovery, dynamic registration and a Client ID Metadata Document, PKCE, bearer requests,
> token refresh, per-owner reuse from the encrypted store, a forged callback, and
> `deauthorize`. [`examples/mcp_oauth.rb`](https://github.com/maquina-app/nexo/blob/main/examples/mcp_oauth.rb)
> signs in to a real server from a terminal. A sign-in against a third-party server has not
> been run from Nexo: the one tried takes only a Client ID Metadata Document, which is the
> host application's to serve.
> store are tested against `ruby_llm`'s real MCP class; a full sign-in against a live
> authorization server has not been run from Nexo.

## Decorating MCP tools

`wrap_mcp_tool` is called once per MCP tool, after it is wrapped in a permission-gating
`MCP::GatedTool` and before it is attached. Override it to decorate every MCP tool an
agent gets — a third-party server's response shape is not yours to change, and its tools
are attached by the harness rather than by you:

```ruby
class MailAgent < Nexo::Agent
  mcp :mail, transport: :stdio, command: "apple-mail-mcp"

  # This server returns an entire message body with no cap; bound it.
  def wrap_mcp_tool(tool)
    CappedTool.new(tool: tool, max_chars: 4_000)
  end
end
```

A wrapper must keep the duck type the chat relies on — `#name`, `#description`,
`#parameters_schema` and `#call`. `ruby_llm` 2.x calls every tool with **keywords**, so
write `def call(**arguments) = …@tool.call(**arguments)`. Delegate everything else with
`method_missing`, as `GatedTool` does, so wrappers compose.

Gating happens **underneath** the wrapper, so it only ever sees an already-authorized
call. Wrapping cannot widen what an agent may do.

← Back to the [README](../README.md)
