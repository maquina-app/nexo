# frozen_string_literal: true

module Nexo
  # Namespace for the pluggable loop backends that drive one prompt to
  # completion: Loops::RubyLLM (the default, provider-neutral) and
  # Loops::AgentSDK (opt-in, Anthropic-oriented). Selected per agent via the
  # +loop:+ constructor injection; the base contract is Nexo::Loop.
  module Loops
    # The default, provider-neutral loop. It is the Spec 1 +Agent#prompt+ body
    # extracted verbatim: build the agent's chat (with its four sandbox-backed
    # tools) and let +ruby_llm+ run the whole tool loop inside +#ask+. It works
    # identically on any +ruby_llm+-supported model — Anthropic, OpenAI, Gemini,
    # Ollama/Gemma — because file/shell capability comes entirely from the
    # agent's own sandbox-backed tools, not from anything vendor-specific here.
    #
    # Tool-call *observability* (not a hard cap — see the turn-cap caveat in the
    # README) is wired through +ruby_llm+'s +before_tool_call+/+after_tool_result+
    # callbacks when the installed version exposes them, and is silently omitted
    # otherwise so an older/newer +ruby_llm+ degrades to no observability rather
    # than crashing.
    class RubyLLM < Nexo::Loop
      # +chat:+ lets a Nexo::Session inject the hydrated, continuing chat so the
      # loop runs over the persisted thread; left nil it builds the agent's own
      # fresh chat exactly as before — the default (no-session) path is unchanged.
      # +max_turns+ is a BUDGET, not a hard stop. ruby_llm runs the whole tool loop
      # inside #ask and its callbacks cannot halt it, so this loop cannot cut a run
      # short. What it can do is COUNT the tool calls and say so: exceeding the budget
      # emits a +:turn_limit_exceeded+ event (once) carrying the count and the limit.
      #
      # Previously the parameter was accepted and never read, which made it look like
      # a safety bound it has never been. Treat it as telemetry: if you need a hard
      # ceiling, bound the work inside your tools, or use Loops::AgentSDK whose engine
      # enforces its own max_turns natively.
      def run(agent:, prompt:, max_turns: 25, chat: nil, &on_event)
        chat ||= agent.chat

        wire_observability(chat, max_turns: max_turns, &on_event)

        response = chat.ask(prompt)
        on_event&.call(:done, response)
        response
      end

      private

      # Tool-call OBSERVABILITY only: ruby_llm runs the whole tool loop inside
      # #ask, so these callbacks report tool activity but cannot halt the loop.
      # BOTH callbacks must be present to wire — confirmed on ruby_llm 1.16.0
      # (legacy aliases of #on_tool_call/#on_tool_result); a chat missing either
      # degrades to no observability rather than crashing on the one it has.
      #
      # A continuing Nexo::Session runs the loop repeatedly over the SAME chat, so
      # the wiring is done once per chat (flagged with an ivar) — otherwise ruby_llm
      # (which *appends* callbacks) would stack a fresh pair every prompt and fire
      # each event N times. The current +on_event+ is stashed on the chat so a later
      # prompt observes with its own block rather than the first one. A fresh chat
      # (the default per-prompt path) simply wires once — byte-for-byte the prior
      # behavior.
      def wire_observability(chat, max_turns: nil, &on_event)
        return unless chat.respond_to?(:before_tool_call) && chat.respond_to?(:after_tool_result)

        chat.instance_variable_set(:@nexo_on_event, on_event)
        chat.instance_variable_set(:@nexo_max_turns, max_turns)
        # The count belongs to the PROMPT, not the chat: a continuing Session runs the
        # loop repeatedly over one chat, and each prompt gets its own budget.
        chat.instance_variable_set(:@nexo_turns, 0)
        chat.instance_variable_set(:@nexo_turns_reported, false)
        return if chat.instance_variable_get(:@nexo_observed)

        chat.instance_variable_set(:@nexo_observed, true)
        chat.before_tool_call do |tc|
          count_turn(chat)
          chat.instance_variable_get(:@nexo_on_event)&.call(:tool_call, tc)
        end
        chat.after_tool_result do |r|
          chat.instance_variable_get(:@nexo_on_event)&.call(:tool_result, r)
        end
      end

      # Counts one tool call and reports the first time the budget is passed. Reported
      # once per prompt, not per call, so a long run does not drown its own event log.
      def count_turn(chat)
        limit = chat.instance_variable_get(:@nexo_max_turns)
        turns = chat.instance_variable_get(:@nexo_turns).to_i + 1
        chat.instance_variable_set(:@nexo_turns, turns)
        return unless limit && turns > limit
        return if chat.instance_variable_get(:@nexo_turns_reported)

        chat.instance_variable_set(:@nexo_turns_reported, true)
        chat.instance_variable_get(:@nexo_on_event)&.call(:turn_limit_exceeded, {turns: turns, max_turns: limit})
      end
    end
  end
end
