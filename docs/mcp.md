# MCP data sources
Attach one or more MCP servers with a single `mcp` macro — every call gated by a second, fail-closed permission axis.

An **MCP server** exposes tools to a model over the [Model Context
Protocol](https://modelcontextprotocol.io) — Gmail, a filesystem, a fetch endpoint,
Drive, and so on. Nexo does not implement MCP; it composes the
[`ruby_llm-mcp`](https://github.com/patvice/ruby_llm-mcp) gem so you attach one or more
servers with a single `mcp` macro and no client wiring. Because a server is reached
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

## Every MCP tool call is gated — and fails closed

MCP tools obey a **second permission axis**, separate from the sandbox capability axis,
because an MCP tool executes inside the server, outside the sandbox. `mcp_allow` is the
exact-match allow-list threaded into the agent's permissions:

| Mode | MCP tool behavior |
|---|---|
| `:read_only` (default) | allow **only** tool names listed in `mcp_allow`; everything else is denied |
| `:ask` | call `on_ask.call(:mcp, {tool:, args:})`; a truthy return allows, else deny |
| `:auto` | allow every MCP tool |

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
2. **Connection lifecycle.** Clients are built once and **memoized on the agent instance**,
   reused across prompts (the `ruby_llm-mcp` client connects on construction and stays
   connected). A long-lived agent holding stdio/SSE servers should call `Agent#close` when
   done to tear the connections down:

   ```ruby
   agent = InboxDigest.new
   agent.prompt("Summarize invoices from this week")
   agent.prompt("Any follow-ups needed?")   # reuses the same live MCP connections
   agent.close                              # stops every attached server
   ```

## HTTP-family servers + an OAuth `token:` provider

Beyond `:stdio`, Nexo attaches a server over any HTTP-family transport `ruby_llm-mcp`
supports — `transport: :http`, `:sse`, or `:streamable`. For an OAuth-authenticated
hosted server (Gmail, Drive, …) add a `token:` — a static bearer `String`, or a
**callable** re-read close to connection time. Nexo resolves it and injects an
`Authorization: Bearer <token>` header per connection:

```ruby
class InboxTriageHTTP < Nexo::Agent
  model       ENV.fetch("NEXO_MODEL")
  permissions :read_only

  # Hosted Gmail MCP server over HTTP; the host supplies the OAuth access token.
  mcp :gmail,
    transport: :http,
    url:       ENV.fetch("GMAIL_MCP_URL"),
    token:     -> { Current.user.gmail_access_token }   # re-read at connection time

  # READ tools only — the unchanged gate denies send/trash/modify.
  mcp_allow %w[search_threads get_thread list_messages get_message list_labels]
end
```

A static token (`token: ENV.fetch("GMAIL_TOKEN")`) is equally valid. Under the hood
Nexo strips `token:` and hands off:

```ruby
RubyLLM::MCP.client(
  name: "gmail", transport_type: :http,
  config: { url: "https://…", headers: { "Authorization" => "Bearer <resolved>" } }
)
```

Any other `headers:` you pass are preserved; Nexo's `Authorization` wins. With no
`token:`, `config:` passes through byte-for-byte (no `headers` key) — the `:stdio` path
is untouched.

**Nexo does not own the OAuth flow.** It performs no authorization-code exchange, no
token refresh, and keeps no token store — that is your app or an OAuth library. Nexo's
only job is to call the provider, inject the header, and hand off. The token is never
logged, persisted, placed in a URL/query string, or emitted in an event (the event path
carries only tool `name`/`args` and return values — never connection config).

**Refresh / reconnect caveat.** `ruby_llm-mcp`'s HTTP-family transports snapshot the
`headers` hash **at construction** — there is no per-request header callback for a plain
`headers` Hash. A callable `token:` is therefore resolved **once**, when the client is
built, and the client is memoized on the agent instance across prompts. So when a token
**rotates**, tear the connection down and reconnect to pick up the new value:

```ruby
agent.close                  # stops the memoized MCP client
agent.prompt("…")            # a fresh prompt rebuilds the client → token: re-resolved
```

**The gate is unchanged.** An HTTP OAuth server's tools are gated exactly like `:stdio`
tools: denied under `:read_only` until the exact name is in `mcp_allow` (default `[]` ⇒
deny-all). Attaching an authenticated server adds no permission surface.

**Two honest caveats — read before attaching a token:**

1. **Refresh may require a reconnect.** Because headers are construction-only,
   a rotated token needs `agent.close` + a fresh prompt (above), not just a new proc
   return. A static token stays constant for the client's life.
2. **The token is a live credential.** Even gated, an authorized MCP call runs its effect
   server-side — a leaked bearer is a real compromise. Nexo keeps it out of logs, events,
   persisted `WorkflowRun` records, and URLs; your host code must do the same. Nexo does
   not police `ruby_llm-mcp`'s own internal logging of headers — that boundary is yours.

`ruby_llm-mcp` is an **optional** dependency — required lazily only when you attach a
server. Without it installed, `require "nexo"` still loads; building a server raises a clear
`Nexo::MissingDependencyError` telling you to add `gem "ruby_llm-mcp"`.

← Back to the [README](../README.md)
