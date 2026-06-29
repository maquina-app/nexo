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

## Configuration

Configure the harness in one place with `Nexo.configure`. Defaults are safe and
provider-neutral — there is intentionally no hardcoded model:

```ruby
Nexo.configure do |config|
  config.default_model       = ENV["NEXO_MODEL"] # provider-neutral: no default
  config.default_sandbox     = :virtual          # :virtual | :local
  config.default_permissions = :read_only        # :read_only | :auto | :ask
  config.skills_path         = "app/skills"
end

Nexo.config.default_sandbox      # => :virtual
Nexo.config.default_permissions  # => :read_only
Nexo.config.default_model        # => nil unless set
```

`require "nexo"` (and `require "nexo_ai"`) works in plain Ruby with no Rails loaded.

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

### Human-gated writes (`:ask`)

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

## Sandboxes & permissions

Two seams compose the execution environment. The **sandbox** is *where* tools act; the
**permission mode** is *what* they may do. A denied capability returns `{ error: ... }`
and the agent loop continues — it does not raise. A path that escapes the workspace raises
`SecurityError`; an agent built with no resolvable model raises `Nexo::ConfigurationError`.

|                          | `:read` | `:glob` | `:write`            | `:shell`                          |
| ------------------------ | ------- | ------- | ------------------- | --------------------------------- |
| `:read_only` (default)   | ✅      | ✅      | ❌ `{error}`        | ❌ `{error}`                      |
| `:auto`                  | ✅      | ✅      | ✅                  | ✅                                |
| `:ask`                   | per `on_ask` | per `on_ask` | per `on_ask`   | per `on_ask`                      |
| `Virtual` sandbox        | ✅      | ✅      | ✅ (in-memory)      | ❌ `NotImplementedError`→`{error}` |
| `Local` sandbox          | ✅ (guarded) | ✅ | ✅ (guarded)        | ✅ (narrowed ENV)                 |

- **`Virtual`** (default) — in-memory, zero host access. `#shell` raises
  `NotImplementedError` on purpose: in-memory means no command execution. That is the
  safety property, not a gap.
- **`Local`** — host filesystem + shell, for trusted dev/CI. Two guards: every path is
  expanded against `cwd` and must stay inside it (else `SecurityError`), and the shell sees
  only `PATH`, `HOME`, `LANG` (plus explicit `env:` additions) — never the full process
  environment.

### Verified vs assumed

Built against **`ruby_llm` 1.16** and **`ruby_llm-test` 0.2**. The tool body method is
`#execute`, tools attach with `chat.with_tools(*instances)`, and instructions set with
`chat.with_instructions`. `Open3.capture3` has no `timeout:` keyword on the target Ruby, so
`Local#shell` bounds the command with `Timeout.timeout`. These may differ on other
`ruby_llm` versions.

### Live smoke (optional)

The core suite is fully offline and deterministic (models stubbed with `ruby_llm-test`).
A real end-to-end check is opt-in and env-gated — small local models like Gemma have weak
tool-calling, so it may be flaky and is never a gating test:

```sh
ollama serve &
NEXO_LIVE=1 NEXO_MODEL=gemma3:12b bundle exec rake test TEST=test/live_smoke_test.rb
```

If Gemma's tool-calling proves too weak, point `NEXO_MODEL` at a stronger model — the gem
stays provider-neutral; only the smoke target changes.

## Requirements

- Ruby 3.2+
- [ruby_llm](https://github.com/crmne/ruby_llm) >= 1.16

## Status

🚧 **Early development.** API is not stable. See [maquina.app](https://maquina.app)
for updates.

## License

MIT — see [LICENSE.txt](LICENSE.txt).
