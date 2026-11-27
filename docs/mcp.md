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

## Every MCP tool call is gated — and fails closed

MCP tools obey a **second permission axis**, separate from the sandbox capability axis,
because an MCP tool executes inside the server, outside the sandbox. `mcp_allow` is the
exact-match allow-list threaded into the agent's permissions:

| Mode | MCP tool behavior |
|---|---|
| `:read_only` (default) | allow **only** tool names listed in `mcp_allow`; everything else is denied |
| `:ask` | call `on_ask.call(:mcp, {tool:, args:})`; a truthy return allows, else deny |
| `:approve` | names in `mcp_allow` are pre-approved; any other tool needs a human decision — undecided **suspends the run** (`Nexo::ApprovalRequired`), `approved: true` allows, `approved: false` denies (the durable sibling of `:ask`) |

Under `:read_only` an MCP tool that is not in `mcp_allow` is not attached at all (0.14): the
model never sees a tool it could not call. Under `:approve` each call is decided on its own —
the tool name and its arguments identify it — so approving one `send_email` does not approve
the next.
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

**Nexo does not own the OAuth flow.** It performs no authorization-code exchange, no
token refresh, and keeps no token store — that is your app or an OAuth library. The token
is never logged, persisted, placed in a URL/query string, or emitted in an event (the
event path carries only tool `name`/`args` and return values — never connection config).

**The gate is unchanged.** An HTTP server's tools are gated exactly like `:stdio`
tools: denied under `:read_only` until the exact name is in `mcp_allow` (default `[]` ⇒
deny-all). Attaching an authenticated server adds no permission surface.

**The token is a live credential.** Even gated, an authorized MCP call runs its effect
server-side — a leaked bearer is a real compromise. Nexo keeps it out of logs, events,
persisted `WorkflowRun` records, and URLs; your host code must do the same. Nexo does
not police `ruby_llm`'s own debug logging (`RUBYLLM_DEBUG`) — that boundary is yours.

`ruby_llm` can also run a full per-user OAuth flow for an MCP server
(`oauth owner:` on a `RubyLLM::MCP` class). Nexo's `mcp` macro does not expose it yet.

> **Upgrading from 0.12:** remove `gem "ruby_llm-mcp"` from your Gemfile. It defines the
> same `RubyLLM::MCP` constant as `ruby_llm` 2.x and the two cannot be bundled together.
> The `mcp` macro and `mcp_allow` are unchanged.


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
