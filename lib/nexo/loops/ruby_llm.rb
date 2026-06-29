# frozen_string_literal: true

module Nexo
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
      def run(agent:, prompt:, max_turns: 25, &on_event)
        chat = agent.chat

        # Turn-count OBSERVABILITY only: ruby_llm runs the whole tool loop inside
        # #ask, so these callbacks report turns and tool activity but cannot halt
        # the loop. Guarded by respond_to? — confirmed present on ruby_llm 1.16.0
        # (legacy aliases of #on_tool_call/#on_tool_result).
        if chat.respond_to?(:before_tool_call)
          # The counter is the documented observability seam: ruby_llm cannot halt
          # the loop mid-#ask, so `turns` is tracked for visibility only and is
          # never used to stop the run (see the README turn-cap caveat).
          turns = 0
          chat.before_tool_call do |tc|
            turns += 1
            on_event&.call(:tool_call, tc)
          end
          chat.after_tool_result { |r| on_event&.call(:tool_result, r) }
        end

        response = chat.ask(prompt)
        on_event&.call(:done, response)
        response
      end
    end
  end
end
