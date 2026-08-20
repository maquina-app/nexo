# Permissions
The permission mode is *what* an agent's tools may do — read-only by default, with `:auto`, `:ask`, and `:approve` escalations; the separate MCP tool gate lives in [MCP](mcp.md).

Two seams compose the execution environment. The **sandbox** is *where* tools act; the
**permission mode** is *what* they may do. A denied capability returns `{ error: ... }`
and the agent loop continues — it does not raise. A path that escapes the workspace raises
`SecurityError`; an agent built with no resolvable model raises `Nexo::ConfigurationError`.

|                          | `:read` | `:glob` | `:write`            | `:shell`                          | `:fetch`   | `:search`  |
| ------------------------ | ------- | ------- | ------------------- | --------------------------------- | ---------- | ---------- |
| `:read_only` (default)   | ✅      | ✅      | ❌ not attached ‡   | ❌ not attached ‡                 | ❌ not attached ‡ | ❌ not attached ‡ |
| `:auto`                  | ✅      | ✅      | ✅                  | ✅                                | ✅         | ✅         |
| `:ask`                   | ✅      | ✅      | per `on_ask`        | per `on_ask`                      | per `on_ask` | per `on_ask` |
| `:approve`               | ✅      | ✅      | per `decision`      | per `decision`                    | per `decision` | per `decision` |
| `Virtual` sandbox        | ✅      | ✅      | ✅ (in-memory)      | ❌ `NotImplementedError`→`{error}` | ✅ †       | ✅ †       |
| `Local` sandbox          | ✅ (guarded) | ✅ | ✅ (guarded)        | ✅ (narrowed ENV)                 | ✅ †       | ✅ †       |
| `Container` sandbox      | ✅ (guarded) | ✅ | ✅ (guarded, scratch) | ✅ (in container)               | ✅ †       | ✅ †       |

`:read`/`:glob` are auto-allowed under **every** mode (they sit in the default
`allow` list), so `:ask`/`:approve` never prompt for them — only
`:write`/`:shell`/`:fetch`/`:search` reach the gate.

**‡** Under `:read_only` these four capabilities can *never* be authorized, so their tools are
not attached at all — the model never sees `WriteFile`, `Shell`, `Fetch` or `WebSearch` in its
schema. Anything named in `allow:` is exempt and attaches normally, and `:auto`/`:ask`/`:approve`
always attach because they decide per call. Leaving a guaranteed failure in the schema is not
free: a model that reads the schema tries the tool, and each attempt costs a full round trip.
`Permissions#never_allows?` is the predicate, and it is derived from the same `PRIVILEGED` list
`#authorize!` uses so the two cannot disagree. This is a cost and description-accuracy measure,
**not** a security boundary — `#authorize!` is still the gate and still denies at call time.

Note that declaring `fetch_allow` or a `search_backend` is *not* a capability grant: `fetch_allow`
scopes which hosts are reachable, and both still need `:fetch` / `:search` permitted before the
tool is attached.

**†** `:fetch` and `:search`
run in the **host process** (stdlib `net/http` / a host-injected backend), so **no
sandbox constrains them** — not even a `--network none` container. They are bounded
only by the capability gate above plus `fetch_allow` / the injected backend.

## Human-gated writes (`:ask`)

`:ask` mode defers every write/shell action to your callback. Build a `Permissions` with
an `on_ask` hook and pass it in:

```ruby
gate = Nexo::Permissions.new(mode: :ask, on_ask: ->(cap, detail) {
  $stdout.print("Allow #{cap} #{detail}? [y/N] "); $stdin.gets.strip == "y"
})

class Editor < Nexo::Agent
  model   ENV.fetch("NEXO_MODEL")
  sandbox :local
end

Editor.new(cwd: ".", permissions: gate).prompt("Fix the typo in README.md")
```

(The bare `:ask` symbol resolves to `Permissions.new(mode: :ask)` with **no** callback, so
writes/shell are denied — pass a pre-built `Permissions` with `on_ask` for a real gate.)

← Back to the [README](../README.md)
