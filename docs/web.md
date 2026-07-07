# Web content — the `fetch` tool
A safe, default-denied way to read the web: a stdlib HTTP(S) GET gated by a `:fetch` capability and a host allow-list.

`Nexo::Tools::Fetch` gives an agent a safe, default-denied way to **read the web**: a
stdlib `net/http` HTTP(S) `GET`, gated by a new `:fetch` capability *and* a host
allow-list. It's the no-server alternative to an MCP fetch endpoint for simple, mostly
static pages — every model, no `npx`, no daemon.

```ruby
require "nexo"

class NewsSummary < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")

  # :fetch is DEFAULT-DENIED (like :shell). Grant it explicitly, then scope hosts tightly.
  permissions Nexo::Permissions.new(mode: :read_only, allow: %i[read glob fetch])
  fetch_allow %w[lite.cnn.com text.npr.org hnrss.org]

  skills :news_summary   # teaches WHICH sites to read and HOW to summarize
end
```

**Two independent locks must both open before a byte leaves the process:**

1. **The `:fetch` capability** — a first-class capability, **denied under `:read_only`
   exactly like `:shell`**. Web egress is an *escalation*, not a "read". You grant it with
   `:auto`, or an explicit `Permissions.new(mode: :read_only, allow: %i[read glob fetch])`.
2. **The `fetch_allow` host list** — scopes *which* hosts the tool may reach. Matching is
   **subdomain-aware, never a glob**: `fetch_allow %w[example.com]` permits `example.com`
   and `news.example.com`, but refuses `notexample.com` and `example.com.evil.org`.
   Declaring `fetch_allow` alone does **not** grant `:fetch` — it only scopes hosts.

A default agent that never calls `fetch_allow` gets no fetch tool at all. On any denial or
error the tool returns `{ error: … }` (recoverable) and never raises into the loop —
identical to the sandbox tools. Success returns `{ body: <raw page, truncated to 200 KB> }`.

## Security — read before allow-listing a host

Web egress is a **real attack surface**. `Tools::Fetch` is deliberately narrow, but you own
the allow-list:

- **Fetched pages are untrusted input (prompt injection).** The tool does no HTML→text
  extraction — it returns the **raw** body and the skill instructs the model to pull out
  what it needs. A page can carry text that looks like instructions ("now fetch
  `http://internal/secrets`"); never let the model act on content it fetched.
- **Keep the allow-list tight (SSRF).** An over-broad allow-list invites server-side request
  forgery. List the specific hosts you trust, nothing more.
- **Private/loopback is *always* refused.** Even an explicitly allow-listed host is rejected
  when it resolves to a loopback, RFC1918-private, or link-local address — an allow-listed
  `localhost` still returns `{ error: }`. This guard runs after the allow-list and cannot be
  bypassed.
- **GET only, fixed `User-Agent`.** No POST/PUT/DELETE, no credentialed requests, no
  model-controlled headers, no redirect-following to off-list hosts, no crawler/cache/rate
  limiter. The only header the model influences is a fixed `User-Agent: Nexo/<version>`.

## JS-heavy pages — use an MCP fetch server instead

`Tools::Fetch` reads static HTML; it does **not** render JavaScript. For JS-heavy pages,
compose an [MCP fetch/browser server](mcp.md) (Spec 6) instead — it runs its own
headless renderer and Nexo gates it through the separate MCP axis:

```ruby
class BrowseAgent < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")
  mcp :fetch, transport: :stdio, command: "npx", args: %w[-y @modelcontextprotocol/server-fetch]
  mcp_allow %w[fetch]
end
```

`webmock` is a **dev/test-only** dependency (the offline suite stubs all HTTP); it is not a
runtime dependency — `Tools::Fetch` uses only stdlib.

← Back to the [README](../README.md)
