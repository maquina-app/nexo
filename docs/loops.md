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
stays valid. Nexo emits a `:turn_limit_exceeded` event and lets the error propagate:

```ruby
begin
  agent.prompt("Triage the inbox", max_turns: 10) do |type, payload|
    warn "over budget: #{payload}" if type == :turn_limit_exceeded
  end
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
- The event also fires, once per prompt, the first time the count of tool **calls** passes
  `max_turns`. A round can hold several calls, so with concurrent tool calls this can
  arrive before the round cap trips. It is a warning; the raise is the stop.
- The cap counts rounds, not time or tokens. Bound those inside your own tools (a read
  tool that accepts at most N ids) or with your provider's limits.

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
