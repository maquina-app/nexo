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
  config.concurrency         = :threaded         # :threaded | :async (opt-in fiber offload)
  config.max_in_flight       = 8                 # Nexo.concurrent fan-out bound
  config.buffer_workflow_events = false          # buffer + flush-once workflow events
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
- **`Remote`** — run the tools inside a remote container (E2B / Daytona / Modal / Docker /
  your own) by injecting a client. Escalating to `:remote` is always an explicit choice in
  your code — the default stays `:virtual`.

### Remote sandbox — bring your own container

`Sandboxes::Remote` contains **zero vendor code**. It wraps any object that satisfies a
four-method contract — `read`, `write`, `exec`, `close` — and delegates the `Sandbox`
interface to it. Switching providers is swapping the injected object, nothing else:

```ruby
sandbox = Nexo::Sandboxes::Remote.new(client: my_container_client)
# read(path)  -> client.read(path)
# write(path, content) -> client.write(path, content)
# shell(cmd, timeout:) -> client.exec(cmd, timeout:)
# glob(pattern)        -> client.exec("ls #{pattern}")[:stdout].split("\n")
# close                -> client.close
```

Vendor SDKs rarely expose exactly `read/write/exec/close`, so adapt them with a tiny shim
object. Keep the vendor gem a **soft** dependency behind a lazy `require` that raises
`Nexo::MissingDependencyError` when it's absent:

```ruby
# A ~10-line adapter wrapping a hypothetical vendor client to the four-method contract.
class E2BAdapter
  def initialize(api_key:)
    require "e2b"            # soft dep — lazy, only when you actually use it
    @sbx = E2B::Sandbox.create(api_key: api_key)
  rescue LoadError
    raise Nexo::MissingDependencyError, "E2BAdapter needs `gem \"e2b\"` in your Gemfile."
  end

  def read(path)            = @sbx.files.read(path)
  def write(path, content)  = @sbx.files.write(path, content)
  def exec(cmd, timeout: 30) = (r = @sbx.commands.run(cmd, timeout: timeout)
                                {stdout: r.stdout, stderr: r.stderr, status: r.exit_code})
  def close                 = @sbx.kill
end

agent = Nexo::Agent.new(model: ENV.fetch("NEXO_MODEL"),
                        sandbox: Nexo::Sandboxes::Remote.new(client: E2BAdapter.new(api_key: ENV["E2B_API_KEY"])))
```

Nexo ships **only** `Remote` plus this documented pattern — purpose-built
`Sandboxes::E2B` / `Sandboxes::Daytona` classes are a possible future addition, deliberately
left out of v1 because their vendor client APIs aren't pinned yet.

## Loop backends — swap the engine, not the agent

The **loop** is the engine that drives one prompt to completion. Swapping it is constructor
injection (`loop:`) — the agent class never changes. Two backends ship:

|                    | `Loops::RubyLLM` (default)         | `Loops::AgentSDK` (opt-in)            |
| ------------------ | ---------------------------------- | ------------------------------------- |
| Provider neutral   | ✅ any `ruby_llm` model            | ❌ Anthropic-oriented                 |
| Tool source        | your sandbox-backed tools          | the SDK's own built-in/host tools     |
| Turn cap           | observability only (see caveat)    | native `max_turns` hard cap           |
| Execution location | your sandbox (virtual/local/remote)| the host process                      |

The whole point: **same agent code, swapped backends**. Both examples are model-agnostic
(`ENV.fetch("NEXO_MODEL")` — never a hardcoded `"claude-…"`):

```ruby
# Claude fast path — AgentSDK's own loop + host tools + native max_turns
claude = Nexo::Agent.new(
  model: ENV.fetch("NEXO_MODEL"),
  sandbox: Nexo::Sandboxes::Local.new(cwd: "/srv/checkout"),
  permissions: Nexo::Permissions.new(mode: :auto),
  loop: Nexo::Loops::AgentSDK.new
)

# Any-provider path — your sandbox, your tools, human-in-the-loop
gpt = Nexo::Agent.new(
  model: ENV.fetch("NEXO_MODEL"),                # gpt-5.5, gemini, gemma3:12b via Ollama…
  sandbox: Nexo::Sandboxes::Remote.new(client: my_container_client),
  permissions: Nexo::Permissions.new(mode: :ask, on_ask: ->(cap, detail) {
    SlackApproval.request!(capability: cap, detail: detail)
  }),
  loop: Nexo::Loops::RubyLLM.new
)
```

`Loops::AgentSDK` wraps `RubyLLM::AgentSDK.query` and requires the **optional**
`ruby_llm-agent_sdk` gem (lazy `require`; a clear `Nexo::MissingDependencyError` if it's
absent). It maps Nexo's permission modes onto the SDK's own vocabulary:

| Nexo mode    | AgentSDK `permission_mode` |
| ------------ | -------------------------- |
| `:read_only` | `:default`                 |
| `:auto`      | `:bypass_permissions`      |
| `:ask`       | `:default` (human gating stays in Nexo's own `on_ask` path, not delegated to the SDK) |

### The turn-cap caveat (read before running untrusted/expensive workloads)

`ruby_llm` runs the whole tool loop inside `ask`, so `Loops::RubyLLM` has **no clean public
hard "stop after N turns" halt** — `before_tool_call` gives turn-count *observability*, not a
hard stop. (Confirmed: `ruby_llm` 1.16.0's `Chat` exposes no public max-turns/max-iterations
setting.) Your three real options:

(a) use `Loops::AgentSDK` (native `max_turns`) for untrusted/expensive workloads;
(b) have a tool return `{ error: "turn limit reached, stop and summarize" }` once a turn
    counter trips;
(c) check whether the installed `ruby_llm` exposes a max-iterations config (in 1.16.0 it
    does not).

Do **not** ship `Loops::RubyLLM` for untrusted workloads claiming a hard cap that isn't
proven.

### Verified vs assumed

Built against **`ruby_llm` 1.16** and **`ruby_llm-test` 0.2**. The tool body method is
`#execute`, tools attach with `chat.with_tools(*instances)`, and instructions set with
`chat.with_instructions`. `Open3.capture3` has no `timeout:` keyword on the target Ruby, so
`Local#shell` bounds the command with `Timeout.timeout`. These may differ on other
`ruby_llm` versions.

`Loops::RubyLLM`'s turn-count observability uses `RubyLLM::Chat#before_tool_call` /
`#after_tool_result`, confirmed present on `ruby_llm` 1.16.0 and guarded with `respond_to?`
so a version lacking them degrades to no observability rather than crashing.
`Loops::AgentSDK` targets `RubyLLM::AgentSDK.query`; `ruby_llm-agent_sdk` is **not** a
dependency of this release, so that signature is **assumed** (per the gem's README) and
verified-on-install — confirm it the moment you add the gem.

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

## Workflows

An **agent** accumulates context — it keeps a conversation going. A **workflow**
fires and finishes: a finite job with a stable runId, a `status`, a `payload`, a
`result`, and an ordered, inspectable event log. Subclass `Nexo::Workflow`,
implement `#call(payload)`, and run it:

```ruby
require "nexo"

class SummarizeDocument < Nexo::Workflow
  def call(payload)
    emit(:started, doc_id: payload[:doc_id])
    summary = payload[:text].to_s.slice(0, 280)   # pure Ruby — no Agent needed
    emit(:summarized, length: summary.length)
    { summary: summary }
  end
end

run = SummarizeDocument.run(doc_id: 123, text: "Long text…")
run.id      # => "0191d6b2-…"  (UUID v7 string, time-ordered)
run.status  # => "done"
run.result  # => { "summary" => "Long text…" }
```

`#call` receives a **symbol-keyed** payload; the stored `payload` and `result`
read back **string-keyed** (they survive a JSON round-trip identically whether
the run lives in memory or in the database).

### Failure model — workflows re-raise

A workflow that raises is recorded as `failed` with the error message **and the
exception still propagates** to your caller:

```ruby
run = BoomWorkflow.run     # raises — but the run is persisted as failed first
# => RuntimeError: kaboom
```

This is deliberately the opposite of a Nexo *tool* failure, which returns
`{ error: … }` and never raises into the agent loop. A tool error is recoverable
context for the model; a workflow failure is a job that did not complete.

Workflows are **not resumable**: an interrupted run is abandoned and you start a
new one. There is no checkpoint state and no `resume`.

### The event log — `emit` and `nexo logs`

`emit(:type, data)` appends an ordered event (`type`, `data`, `at`) and persists
it incrementally. Inspect a run's log in plain Ruby:

```ruby
Nexo::Workflow.logs(run.id) { |ev| puts "#{ev["at"]} #{ev["type"]}" }
```

or, in a Rails app, from the terminal:

```sh
$ bundle exec rake "nexo:logs[0191d6b2-7c4a-7e1f-9a3b-2f5c8d1e6b00]"
[2026-06-29T14:02:01Z] started      {"doc_id"=>123}
[2026-06-29T14:02:01Z] summarized   {"length"=>280}
```

### With or without Rails

With no Rails loaded, runs record to an in-memory store — workflows run, emit,
and `Nexo::Workflow.logs` works, all offline with no database. In a Rails app,
install the migration and runs persist to a `nexo_workflow_runs` table:

```sh
rails g nexo:workflows
rails db:migrate
```

The same `Workflow` code drives either backend; `Nexo::RunStore.default` selects
ActiveRecord when it is available and the in-memory store otherwise. The schema
uses portable `json` columns (SQLite and PostgreSQL alike) and a UUID string
primary key.

## Concurrency (opt-in async)

Async is **entirely optional**. Nexo installs and runs synchronously with no
`async` gem present, and only complains if you actually use a concurrency
feature. The `async` gem is a soft dependency — add it yourself when you want
fan-out:

```ruby
gem "async", "~> 2.0"
```

Two facts make this cheap:

- **LLM calls are already async-compatible.** `ruby_llm` speaks HTTP over
  Faraday's `net/http` adapter, which yields on socket I/O under Ruby's fiber
  scheduler. `Loops::RubyLLM` therefore runs unchanged inside a reactor — no API
  change, no rewrite. Wrapping a *single* `agent.prompt` in `Async {}` gains
  nothing; async only pays off under fan-out.
- **The value Nexo adds is rate-bounded fan-out.** `Nexo.concurrent` bounds
  in-flight work so you don't trip provider rate limits, and propagates the first
  error instead of swallowing it.

### `Nexo.concurrent` — bounded fan-out

```ruby
# 100 docs, but never more than 8 provider calls in flight; results in doc order.
results = Nexo.concurrent(max_in_flight: 8) do |c|
  Document.find_each { |d| c.add { SummarizeDocument.run(doc_id: d.id, text: d.body).result } }
end
```

Every block added with `c.add { … }` runs inside **one** `async` reactor,
capped at `max_in_flight` in flight (an `Async::Semaphore`) and coordinated by an
`Async::Barrier`. Results come back as an Array in **submission order** (not
completion order). On the first task that raises, that error is **re-raised** and
the remaining in-flight tasks are stopped — errors are never swallowed.
`max_in_flight` defaults to `Nexo.config.max_in_flight` (`8`) and is the single
most important knob for staying under provider rate limits.

Using `Nexo.concurrent` with `async` not installed raises
`Nexo::MissingDependencyError` with install guidance.

### `Sandboxes::Local` offload

Under a reactor, blocking file/subprocess I/O would stall every other fiber. Flip
the switch and `Sandboxes::Local` offloads its `read`/`write`/`glob`/`shell` to a
worker thread:

```ruby
Nexo.configure { |c| c.concurrency = :async }   # default is :threaded
```

The decision is driven by config, not by scheduler detection: under `:async` the
blocking block runs on a worker thread so the reactor keeps serving other fibers;
under `:threaded` (the default) it runs inline with zero overhead — byte-for-byte
the synchronous behavior. Offloading changes neither return values nor the
security properties: the path-escape guard, narrowed ENV, and `Timeout`-wrapped
subprocess are all preserved. (`Sandboxes::Virtual` is pure memory and
`Sandboxes::Remote` is already HTTP/fiber-friendly — neither needs offload.)

### `Workflow` buffered emit

Each `emit` normally persists immediately. Under a reactor that per-event DB write
blocks the whole loop, so `Workflow.run` takes a `buffer_events:` flag (default
`Nexo.config.buffer_workflow_events`, `false`):

```ruby
run = SummarizeDocument.run({doc_id: 1, text: body}, buffer_events: true)
# events buffer in memory and flush to the store exactly once, on completion
```

With buffering on, events accumulate in memory and flush in a single
`save_events!` at the end of the run (on both success and failure). The default
(unbuffered) behavior is unchanged.

### Running under Rails / a fiber server

Async DB work is the sharp edge. Under a fiber server such as
[Falcon](https://github.com/socketry/falcon), many concurrent queries can exhaust
the ActiveRecord connection pool, so:

- **Raise `DB_POOL`** (the connection-pool size) to cover your in-flight
  concurrency.
- On **Rails 7.1+**, consider
  `config.active_record.async_query_executor`.
- Prefer `buffer_events: true` for workflows so each run writes its event log
  once instead of per event.

Note that DB work under a reactor is *offloaded/pooled*, not truly fiber-async —
Nexo does not ship a fiber-native DB driver. For server setup (Falcon, the fiber
scheduler), see the [`async` guide](https://socketry.github.io/async/).

## Skills

A **skill** is a `SKILL.md` package — frontmatter plus instructions — that teaches the
model *how you want a task done*. Skills guide **reasoning**; the sandbox-backed tools
above perform **execution**. Nexo does not implement skill loading; it composes the
[`ruby_llm-skills`](https://github.com/kieranklaassen/ruby_llm-skills) gem so you attach a
skill with one macro and no loader setup.

Drop a package under `app/skills/` (or scaffold one — see below):

```
app/skills/
└── triage/
    ├── SKILL.md          # frontmatter (name, description) + process steps
    └── references/       # supporting docs the skill can cite
```

```markdown
---
name: triage
description: Triage incoming issues by severity and route them to the right owner.
---

# Triage

## Process
1. Classify the issue severity.
2. Route to the right owner.
```

Reference it with the `skills` macro — its instructions are layered on top of the agent's
own, in declaration order:

```ruby
require "nexo"

class TriageAgent < Nexo::Agent
  model ENV.fetch("NEXO_MODEL")   # any ruby_llm model — never a hardcoded vendor default
  skills :triage                  # one macro, no loader wiring
end

TriageAgent.new.chat   # chat built with the base sandbox tools + the skill's instructions
```

Scaffold a new skill package with the generator (creates a valid `SKILL.md` plus a
`references/` directory):

```sh
rails g nexo:skill triage
#   create  app/skills/triage/references/.keep
#   create  app/skills/triage/SKILL.md
```

`ruby_llm-skills` is an **optional** dependency — required lazily only when you use a skill.
Without it installed, `require "nexo"` still loads; touching a skill raises a clear
`Nexo::MissingDependencyError` telling you to add `gem "ruby_llm-skills"`. Referencing a
skill that does not exist raises `Nexo::Error` naming the missing `SKILL.md` path.

### Skill tools stay gated

A skill contributes **instructions only**. A loaded skill ships no independent tools, and
Nexo deliberately does not attach `ruby_llm-skills`' progressive-disclosure tool (which
reads files outside the sandbox). The model reaches a skill's `references/`/`scripts/`
files through Nexo's own permission-gated, sandbox-backed tools — so **attaching a skill
never widens what an agent can do** beyond its configured sandbox/permission mode.

## MCP data sources

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

### Every MCP tool call is gated — and fails closed

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

`ruby_llm-mcp` is an **optional** dependency — required lazily only when you attach a
server. Without it installed, `require "nexo"` still loads; building a server raises a clear
`Nexo::MissingDependencyError` telling you to add `gem "ruby_llm-mcp"`.

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
