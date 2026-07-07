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
    # Turn-count *observability* (not a hard cap — see the turn-cap caveat in the
    # README) is wired through +ruby_llm+'s +before_tool_call+/+after_tool_result+
    # callbacks when the installed version exposes them, and is silently omitted
    # otherwise so an older/newer +ruby_llm+ degrades to no observability rather
    # than crashing.
    class RubyLLM < Nexo::Loop
      # +chat:+ lets a Nexo::Session inject the hydrated, continuing chat so the
      # loop runs over the persisted thread; left nil it builds the agent's own
      # fresh chat exactly as before — the default (no-session) path is unchanged.
      def run(agent:, prompt:, max_turns: 25, chat: nil, &on_event)
        chat ||= agent.chat

        wire_observability(chat, &on_event)

        response = chat.ask(prompt)
        on_event&.call(:done, response)
        response
      end

      private

      # Turn-count OBSERVABILITY only: ruby_llm runs the whole tool loop inside
      # #ask, so these callbacks report turns and tool activity but cannot halt the
      # loop. Guarded by respond_to? — confirmed present on ruby_llm 1.16.0 (legacy
      # aliases of #on_tool_call/#on_tool_result); a chat lacking them degrades to
      # no observability rather than crashing.
      #
      # A continuing Nexo::Session runs the loop repeatedly over the SAME chat, so
      # the wiring is done once per chat (flagged with an ivar) — otherwise ruby_llm
      # (which *appends* callbacks) would stack a fresh pair every prompt and fire
      # each event N times. The current +on_event+ is stashed on the chat so a later
      # prompt observes with its own block rather than the first one. A fresh chat
      # (the default per-prompt path) simply wires once — byte-for-byte the prior
      # behavior.
      def wire_observability(chat, &on_event)
        return unless chat.respond_to?(:before_tool_call)

        chat.instance_variable_set(:@nexo_on_event, on_event)
        return if chat.instance_variable_get(:@nexo_observed)

        chat.instance_variable_set(:@nexo_observed, true)
        # The counter is the documented observability seam: ruby_llm cannot halt
        # the loop mid-#ask, so `turns` is tracked for visibility only and is never
        # used to stop the run (see the README turn-cap caveat).
        turns = 0
        chat.before_tool_call do |tc|
          turns += 1
          chat.instance_variable_get(:@nexo_on_event)&.call(:tool_call, tc)
        end
        chat.after_tool_result do |r|
          chat.instance_variable_get(:@nexo_on_event)&.call(:tool_result, r)
        end
      end
    end
  end
end
