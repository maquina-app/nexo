# Permissions
The permission mode is *what* an agent's tools may do — read-only by default, with `:auto`, `:ask`, and `:approve` escalations; the separate MCP tool gate lives in [MCP](mcp.md).

Two seams compose the execution environment. The **sandbox** is *where* tools act; the
**permission mode** is *what* they may do. A denied capability returns `{ error: ... }`
and the agent loop continues — it does not raise. A path that escapes the workspace raises
`SecurityError`; an agent built with no resolvable model raises `Nexo::ConfigurationError`.

|                          | `:read` | `:glob` | `:write`            | `:shell`                          | `:fetch`   | `:search`  |
| ------------------------ | ------- | ------- | ------------------- | --------------------------------- | ---------- | ---------- |
| `:read_only` (default)   | ✅      | ✅      | ❌ `{error}`        | ❌ `{error}`                      | ❌ `{error}` | ❌ `{error}` |
| `:auto`                  | ✅      | ✅      | ✅                  | ✅                                | ✅         | ✅         |
| `:ask`                   | ✅      | ✅      | per `on_ask`        | per `on_ask`                      | per `on_ask` | per `on_ask` |
| `:approve`               | ✅      | ✅      | per `decision`      | per `decision`                    | per `decision` | per `decision` |
| `Virtual` sandbox        | ✅      | ✅      | ✅ (in-memory)      | ❌ `NotImplementedError`→`{error}` | ✅ †       | ✅ †       |
| `Local` sandbox          | ✅ (guarded) | ✅ | ✅ (guarded)        | ✅ (narrowed ENV)                 | ✅ †       | ✅ †       |
| `Container` sandbox      | ✅ (guarded) | ✅ | ✅ (guarded, scratch) | ✅ (in container)               | ✅ †       | ✅ †       |

`:read`/`:glob` are auto-allowed under **every** mode (they sit in the default
`allow` list), so `:ask`/`:approve` never prompt for them — only
`:write`/`:shell`/`:fetch`/`:search` reach the gate. **†** `:fetch` and `:search`
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
