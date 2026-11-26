# frozen_string_literal: true

module Nexo
  # Namespace for the loop backends that drive one prompt to completion.
  # Loops::RubyLLM is the default and the only one Nexo ships; a custom backend
  # subclasses Nexo::Loop and is selected per agent via the `loop:` constructor
  # injection.
  module Loops
    # The default, provider-neutral loop: build the agent's chat (with its
    # sandbox-backed tools) and let `ruby_llm` run the whole tool loop inside
    # `#ask`. It works identically on any `ruby_llm`-supported model — Anthropic,
    # OpenAI, Gemini, Ollama/Gemma — because file/shell capability comes entirely
    # from the agent's own sandbox-backed tools, not from anything vendor-specific
    # here.
    #
    # Tool activity is reported through `ruby_llm`'s `before_tool_call` /
    # `after_tool_result` callbacks, and the turn cap is `ruby_llm`'s own
    # `with_tool_options(rounds:)`.
    class RubyLLM < Nexo::Loop
      # `chat:` lets a Nexo::Session inject the hydrated, continuing chat so the
      # loop runs over the persisted thread; left nil it builds the agent's own
      # fresh chat.
      #
      # `max_turns` is a HARD CAP on tool rounds: the number of model responses
      # that ask for tools within this one prompt, however many calls each holds.
      # When the cap is reached `ruby_llm` raises `RubyLLM::ToolRoundLimitError`
      # instead of asking the model again. Every tool call that ran has its
      # result, so the conversation stays valid. This loop emits a
      # `:turn_limit_exceeded` event and lets the error propagate — a run that
      # blows its budget fails loudly rather than continuing unbounded. Pass
      # `max_turns: nil` to run uncapped.
      def run(agent:, prompt:, max_turns: 25, chat: nil, &on_event)
        chat ||= agent.chat

        wire_observability(chat, max_turns: max_turns, &on_event)
        chat.with_tool_options(rounds: max_turns) if chat.respond_to?(:with_tool_options)

        response = chat.ask(prompt)
        on_event&.call(:done, response)
        response
      rescue ::RubyLLM::ToolRoundLimitError
        report_turn_limit(chat, max_turns)
        raise
      end

      private

      # Tool-call OBSERVABILITY: these callbacks report tool activity; the cap
      # itself is `with_tool_options(rounds:)` in #run. BOTH callbacks must be
      # present to wire (verified on ruby_llm 2.2.3, where they are additive); a
      # chat double missing either degrades to no observability rather than
      # crashing on the one it has.
      #
      # A continuing Nexo::Session runs the loop repeatedly over the SAME chat, so
      # the wiring is done once per chat (flagged with an ivar) — otherwise ruby_llm
      # (which *appends* callbacks) would stack a fresh pair every prompt and fire
      # each event N times. The current `on_event` is stashed on the chat so a later
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

      # Counts one tool call. A round may hold several calls, so the count can pass
      # `max_turns` before the round cap trips; the first time it does, that is
      # reported once per prompt so a long run does not drown its own event log.
      def count_turn(chat)
        limit = chat.instance_variable_get(:@nexo_max_turns)
        turns = chat.instance_variable_get(:@nexo_turns).to_i + 1
        chat.instance_variable_set(:@nexo_turns, turns)
        report_turn_limit(chat, limit) if limit && turns > limit
      end

      # Emits `:turn_limit_exceeded` at most once per prompt, carrying the tool-call
      # count so far and the limit.
      def report_turn_limit(chat, limit)
        return if chat.instance_variable_get(:@nexo_turns_reported)

        chat.instance_variable_set(:@nexo_turns_reported, true)
        turns = chat.instance_variable_get(:@nexo_turns).to_i
        chat.instance_variable_get(:@nexo_on_event)&.call(:turn_limit_exceeded, {turns: turns, max_turns: limit})
      end
    end
  end
end
