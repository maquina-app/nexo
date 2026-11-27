# The loop — one engine, a real turn cap
The loop is the engine that drives one prompt to completion; `max_turns` is a hard cap on its tool rounds.

The **loop** is the engine that drives one prompt to completion. Nexo ships one,
`Nexo::Loops::RubyLLM`, and it is the default: it builds the agent's chat with its
sandbox-backed tools and lets `ruby_llm` run the tool loop. It works identically on any
`ruby_llm`-supported model — Anthropic, OpenAI, Gemini, a local model through Ollama —
because every capability comes from the agent's own gated tools, not from anything
vendor-specific.

```ruby
agent = Nexo::Agent.new(
  model: ENV.fetch("NEXO_MODEL"),                # gpt-5.5, gemini, gemma3:12b via Ollama…
  sandbox: Nexo::Sandboxes::Remote.new(client: my_container_client),
  permissions: Nexo::Permissions.new(mode: :ask, on_ask: ->(cap, detail) {
    SlackApproval.request!(capability: cap, detail: detail)
  })
)
```

The loop is still a seam. A backend of your own subclasses `Nexo::Loop`, implements
`run(agent:, prompt:, max_turns:, chat:, &on_event)`, and is injected with `loop:` — the
agent class never changes.

> `Loops::AgentSDK` was removed in 0.13. It wrapped a `ruby_llm-agent_sdk` gem that was
> never published, and its one purpose — a hard turn cap — is now native (below).

## `max_turns` is a hard cap

`Agent#prompt`, `Session#prompt` and `Workflow#run_agent` all take `max_turns:` (default
`25`). It caps **tool rounds**: the number of model responses that ask for tools within
one prompt, however many calls each response holds. Nexo passes it to `ruby_llm` as
`with_tool_options(rounds:)`.

When the cap is reached, `ruby_llm` raises `RubyLLM::ToolRoundLimitError` instead of
asking the model again. Every tool call that ran has its result, so the conversation
stays valid. The error propagates:

```ruby
begin
  agent.prompt("Triage the inbox", max_turns: 10)
rescue RubyLLM::ToolRoundLimitError
  # the run used its 10 rounds — decide whether to retry with a larger budget
end
```

Inside a workflow the error fails the run like any other (`status: "failed"`, re-raised),
so a runaway agent cannot keep spending.

`max_turns` counts model responses, and one response may ask for any number of tool calls.
`Nexo.config.tool_calls_per_round` (default `20`) caps how many of them run: calls past the
cap are answered with an error straight away and never execute. With the defaults a prompt
is bounded at 25 rounds of 20 calls. Set it to `nil` for no cap.

Things to know:

- **Upgrading from 0.12:** `max_turns` used to be telemetry only — a run that passed it
  kept going. It now stops. If a legitimate run needs more rounds, raise the number.
- `max_turns: nil` runs uncapped. Use it only for trusted workloads.
- There is no event for it. The `:turn_limit_exceeded` event was removed in 0.16; rescue
  `RubyLLM::ToolRoundLimitError`. One round can hold several tool calls, and
  `Nexo.config.tool_calls_per_round` (default 20) bounds those.
- The cap counts rounds, not time or tokens. Bound those inside your own tools (a read
  tool that accepts at most N ids) or with your provider's limits.

## What the block receives

`Agent#prompt` yields `(type, payload)` as the prompt runs:

| Event | Payload | When |
|---|---|---|
| `:tool_call` | `RubyLLM::ToolCall` | before each tool call |
| `:tool_progress` | `{tool_call:, progress:}` — a `RubyLLM::Progress` (`message`, `value`, `total`) | when a tool reports progress (0.16) |
| `:tool_result` | the tool's return value | after each tool call |
| `:fallback` | `RubyLLM::Fallback` (`from`, `to`, `error`) | after a request moved to a fallback model declared in the `llm` block (0.16) |
| `:done` | the final `RubyLLM::Message` | when the prompt ends |
| `:usage` | `{tokens: {input_tokens:, output_tokens:, …}, cost:}` | once per prompt, last, **even when the prompt raises** (0.16) |

`:usage` is what this prompt added, so it is right for a session's long-lived chat too. `cost`
is `nil` when `ruby_llm` has no price for the model. The `:turn_limit_exceeded` event was
removed in 0.16: rescue `RubyLLM::ToolRoundLimitError`. A call declined under `:approve` emits
no tool events, because `ruby_llm` answers it without entering the tool.

`:fallback` was run live in 0.16 (`test/live_smoke_test.rb`): a primary model whose provider
could not be reached, falling back to a model on Ollama.

A tool of your own reports progress with `progress "Reading page 3 of 9", value: 3, total: 9`
and ends the turn with `halt "Filed as billing"` — both `RubyLLM::Tool` methods, and both work
through the permission gate.

### Stopping a prompt

`prompt(text, cancel: -> { stop_requested? })` asks the callable around every tool call. When
it answers true the chat is cancelled and the prompt raises `RubyLLM::CancelledError` before
the next tool call or model request; a request already in flight finishes first. A workflow
does this for you — see [`Workflow.cancel`](durable-workflows.md).

### A tool that asks the person something

A tool can stop and ask: an MCP server's question, or a `RubyLLM::Tool` that calls `ask`.
`prompt` then raises `Nexo::InputRequired`, whose `questions` say what to collect (`key`,
`tool`, `message`, `fields`). Put them to the person and prompt again with the answers:

```ruby
begin
  Booker.new.prompt("Book me a seat to Lisbon")
rescue Nexo::InputRequired => e
  answers = e.questions.to_h { |q| [q.key, ask_the_person(q)] }
  Booker.new(answers: answers).prompt("Book me a seat to Lisbon")
end
```

A value answers a one-field question, a Hash a form, `false` declines. Inside a workflow the
run suspends and resumes with the answers instead.

## Verified against

Built and tested against **`ruby_llm` 2.2.3** (the gemspec pins `~> 2.2.0`). The tool body
method is `#execute`; the chat calls a tool as `tool.call(**arguments)`; tools attach with
`chat.with_tools(*instances)`; execution settings go through `chat.with_tool_options`;
instructions set with `chat.with_instructions`. Tool activity is observed with
`Chat#before_tool_call` / `#after_tool_result`, which are additive.

These facts are not taken on trust: `test/real_loop_test.rb` drives `ruby_llm`'s real
conversation loop with scripted model replies and asserts the permission gate, the MCP
gate, the turn cap, and approval suspension end to end.

`Open3.capture3` has no `timeout:` keyword on the target Ruby, so `Local#shell` bounds the
command with `Timeout.timeout`.

## Live smoke (optional)

The core suite is fully offline and deterministic (model replies are scripted with
`ruby_llm`'s own `RubyLLM::TestHelper`). A real end-to-end check is opt-in and env-gated —
small local models like Gemma have weak tool-calling, so it may be flaky and is never a
gating test:

```sh
ollama serve &
NEXO_LIVE=1 NEXO_MODEL=gemma3:12b bundle exec rake test TEST=test/live_smoke_test.rb
```

If Gemma's tool-calling proves too weak, point `NEXO_MODEL` at a stronger model — the gem
stays provider-neutral; only the smoke target changes.

← Back to the [README](../README.md)
