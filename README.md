# Nexo

> Agent = Model + Harness. Nexo is the connective tissue linking RubyLLM to tools,
> sandboxes, skills, and runs.

A model alone forgets everything the moment a response ends. The harness is everything
else. Nexo gives the RubyLLM ecosystem one cohesive front door with safe defaults —
build a working agent in five lines without wiring anything.

## Compose, don't reimplement

Nexo does not rebuild skill loading, the tool-call loop, MCP, or structured output — those
already live in the RubyLLM ecosystem (`ruby_llm` core, `ruby_llm-skills`, `ruby_llm-mcp`,
`ruby_llm-schema`). Nexo **composes** them behind one front door and adds only the two pieces
the ecosystem is missing:

- **Sandbox + Permissions seam** — pluggable execution environment (virtual / local /
  remote) with explicit authorization gating. Default: `:virtual` + `:read_only`.
- **WorkflowRun lifecycle** — a finite-job primitive (runId, status, payload, result,
  inspectable event log) that nothing else in the ecosystem provides cleanly.

## Installation

Add to your Gemfile:

```ruby
gem "nexo_ai"
```

Or install directly:

```sh
gem install nexo_ai
```

In a Rails app, run the install generator to create the conventional layout and an initializer:

```sh
rails g nexo:install
```

```
      create  app/agents/.keep
      create  app/workflows/.keep
      create  app/skills/.keep
      create  config/initializers/nexo.rb
```

## Build an agent in five lines

Subclass `Nexo::Agent`, declare the pieces with class macros, and call `#prompt`. No
sandbox, permission, or tool object is wired by hand, and nothing is vendor-specific —
the agent runs on any `ruby_llm`-supported model (set `NEXO_MODEL`, e.g. a local
`gemma3:12b` via Ollama, or a hosted model):

```ruby
require "nexo"

class CodeReviewer < Nexo::Agent
  model       ENV.fetch("NEXO_MODEL")   # any ruby_llm model — never a hardcoded vendor default
  sandbox     :local
  permissions :read_only

  instructions "You are a careful code reviewer. Read files and report issues. Do not write files."
end

CodeReviewer.new(cwd: "/path/to/repo").prompt("Review the auth module")
```

Defaults are safe: an agent with no `sandbox`/`permissions` declared gets the in-memory
`:virtual` sandbox and `:read_only` permissions, so an untrusted model has zero host
access until you explicitly opt in.

> **Safe by default:** agents start `:virtual` + `:read_only` — an untrusted model has zero host access until you explicitly opt in.

## Documentation

| Guide | What's inside |
|-------|---------------|
| [Getting started](docs/getting-started.md) | install, configuration, first agent |
| [Sandboxes](docs/sandboxes.md) | Virtual / Local / Remote / Container + hardened defaults |
| [Permissions](docs/permissions.md) | modes, the gate, MCP gate, :ask |
| [Tools](docs/tools.md) | ReadFile / WriteFile / Shell / Glob |
| [Loop backends](docs/loops.md) | RubyLLM vs AgentSDK, turn-cap caveat |
| [Workflows](docs/workflows.md) | lifecycle, staging, artifacts, run_agent |
| [Durable workflows](docs/durable-workflows.md) | checkpoint / suspend / resume |
| [Skills](docs/skills.md) | SKILL.md packages, gated tools |
| [MCP](docs/mcp.md) | mcp macro, fail-closed gate, transports |
| [Web](docs/web.md) | fetch tool + SSRF guard, search tool + injected backend |
| [Sessions](docs/sessions.md) | continuing, addressable memory |
| [Rails](docs/rails.md) | engine, run_later, broadcasting, generators |
| [Concurrency](docs/concurrency.md) | opt-in async, buffered emit, fiber servers |

## Requirements

- Ruby 3.3+
- [ruby_llm](https://github.com/crmne/ruby_llm) >= 1.16
- [ruby_llm-skills](https://github.com/kieranklaassen/ruby_llm-skills) — optional, only
  when you use the `skills` macro
- [ruby_llm-mcp](https://github.com/patvice/ruby_llm-mcp) — optional, only when you attach
  an MCP server with the `mcp` macro
- [ruby_llm-agent_sdk](https://github.com/crmne/ruby_llm) — optional, only when you choose
  the Anthropic-oriented `Loops::AgentSDK` backend

## Status

🚧 **Early development.** API is not stable. See [maquina.app](https://maquina.app)
for updates.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
