# Loop backends — swap the engine, not the agent
The loop is the engine that drives one prompt to completion; swap it by constructor injection without touching the agent class.

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
| `:approve`   | `:default` (durable approval stays in Nexo's own gate; any unmapped mode also falls back to `:default`) |

## The turn-cap caveat (read before running untrusted/expensive workloads)

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

## Verified vs assumed

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

## Live smoke (optional)

The core suite is fully offline and deterministic (models stubbed with `ruby_llm-test`).
A real end-to-end check is opt-in and env-gated — small local models like Gemma have weak
tool-calling, so it may be flaky and is never a gating test:

```sh
ollama serve &
NEXO_LIVE=1 NEXO_MODEL=gemma3:12b bundle exec rake test TEST=test/live_smoke_test.rb
```

If Gemma's tool-calling proves too weak, point `NEXO_MODEL` at a stronger model — the gem
stays provider-neutral; only the smoke target changes.


## `max_turns` is a budget, not a hard stop

`Agent#prompt`, `Session#prompt` and `Workflow#run_agent` all take `max_turns:`. On the
default `Loops::RubyLLM` it **cannot halt a run**: ruby_llm executes the entire tool loop
inside `Chat#ask`, and the callbacks Nexo wires are observation-only.

What it does do is count tool calls and tell you when the budget is passed:

```ruby
agent.prompt("Triage the inbox", max_turns: 10) do |type, payload|
  warn "over budget: #{payload}" if type == :turn_limit_exceeded
end
# => :turn_limit_exceeded, { turns: 11, max_turns: 10 }
```

Emitted once per prompt, not per call.

If you need a **hard** ceiling, the options are:

- bound the work inside your own tools (a read tool that accepts at most N ids);
- use `Loops::AgentSDK`, whose engine enforces `max_turns` natively;
- stop the run yourself from the event block.

Treat `max_turns` on the default loop as telemetry. It was previously accepted and never
read, which made it look like a safety bound it has never been.

← Back to the [README](../README.md)
