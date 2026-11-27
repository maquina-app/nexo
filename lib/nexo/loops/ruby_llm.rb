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
      # result, so the conversation stays valid. The error propagates — a run
      # that blows its budget fails loudly rather than continuing unbounded.
      # Pass `max_turns: nil` to run uncapped.
      #
      # `cancel:` (0.16) is a callable asked before and after every tool call;
      # when it answers true the chat is cancelled and `ruby_llm` raises
      # `RubyLLM::CancelledError` at its next checkpoint — before the next tool
      # call or model request.
      #
      # Besides `:tool_call`, `:tool_result` and `:done`, the block receives
      # `:tool_progress` (a tool's `progress` reports), `:fallback` (a request
      # that moved to a fallback model) and, once per prompt even when it
      # raises, `:usage` with the tokens and cost this prompt added.
      def run(agent:, prompt:, max_turns: 25, chat: nil, cancel: nil, &on_event)
        chat ||= agent.chat

        wire_observability(chat, cancel: cancel, &on_event)
        chat.with_tool_options(rounds: max_turns) if chat.respond_to?(:with_tool_options)
        before = usage_of(chat)

        response = settle_questions(agent, chat, chat.ask(prompt))
        on_event&.call(:done, response)
        response
      ensure
        report_usage(chat, before, &on_event) if chat && before
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
      def wire_observability(chat, cancel: nil, &on_event)
        return unless chat.respond_to?(:before_tool_call) && chat.respond_to?(:after_tool_result)

        chat.instance_variable_set(:@nexo_on_event, on_event)
        chat.instance_variable_set(:@nexo_cancel, cancel)
        return if chat.instance_variable_get(:@nexo_observed)

        chat.instance_variable_set(:@nexo_observed, true)
        chat.before_tool_call do |tc|
          chat.instance_variable_get(:@nexo_on_event)&.call(:tool_call, tc)
          cancel_if_requested(chat)
        end
        chat.after_tool_result do |r|
          chat.instance_variable_get(:@nexo_on_event)&.call(:tool_result, r)
          cancel_if_requested(chat)
        end
        wire_optional(chat)
      end

      # The callbacks a chat double may not have. `after_tool_progress` hands over
      # the tool call and a `RubyLLM::Progress`; `after_fallback` a
      # `RubyLLM::Fallback` once the attempt on the other model has ended.
      def wire_optional(chat)
        if chat.respond_to?(:after_tool_progress)
          chat.after_tool_progress do |tool_call, progress|
            chat.instance_variable_get(:@nexo_on_event)&.call(:tool_progress, {tool_call: tool_call, progress: progress})
          end
        end
        return unless chat.respond_to?(:after_fallback)

        chat.after_fallback { |fallback| chat.instance_variable_get(:@nexo_on_event)&.call(:fallback, fallback) }
      end

      # Cancels the chat when the prompt's `cancel:` callable says so. A failing
      # callable never breaks the prompt: it is read as "not cancelled".
      def cancel_if_requested(chat)
        requested = chat.instance_variable_get(:@nexo_cancel)&.call
        chat.cancel if requested && chat.respond_to?(:cancel)
      rescue ::RubyLLM::CancelledError
        raise
      rescue
        nil
      end

      # `ruby_llm` pauses a tool call that waits on a person, and `ask` returns
      # with the chat waiting. Two things wait on a person:
      #
      # * an approval — a call under an `:approve` gate with no recorded decision
      #   (see Approvable). It raises Nexo::ApprovalRequired carrying every such
      #   call. Recorded decisions never reach here: the tool's resolver reads
      #   them and `ruby_llm` runs or refuses the call itself.
      # * a question a tool asked. Answers the agent was given
      #   (`Agent.new(answers:)`) are applied and the turn carried on; a question
      #   with no answer raises Nexo::InputRequired.
      def settle_questions(agent, chat, response)
        return response unless chat.respond_to?(:waiting?) && chat.respond_to?(:pending_questions)

        answers = agent.respond_to?(:answers) ? agent.answers.to_h : {}
        while chat.waiting?
          approvals, questions = chat.pending_questions.partition(&:approval?)
          require_approvals(agent, chat, approvals)
          break if questions.empty? && approvals.empty?

          unanswered = questions.reject { |question| answer(question, answers) }
          raise Nexo::InputRequired.new(unanswered.map { |q| Nexo::InputRequired.reduce(q) }) unless unanswered.empty?

          response = chat.complete
        end
        response
      end

      # Raises Nexo::ApprovalRequired for the approvals still undecided. An
      # approval a host's own tool asks for (`requires_approval` on a
      # `RubyLLM::Tool`) is decided from the agent's decisions too, under
      # `tool:<name>` and its arguments.
      def require_approvals(agent, chat, approvals)
        decisions = agent.respond_to?(:permissions) ? agent.permissions.decisions.to_h : {}
        waiting = approvals.filter_map do |question|
          subject = approval_subject(chat, question.tool_call)
          decided = decisions[Nexo::Permissions.approval_key(*subject)]
          next subject if decided.nil?

          decided ? question.approve : question.decline
          nil
        end
        return if waiting.empty?

        pending = waiting.map { |subject| Nexo::ApprovalRequired.new(*subject).to_h }
        raise Nexo::ApprovalRequired.new(*waiting.first, pending: pending)
      end

      # What `tool_call` is decided under: the tool's own subject when it is one
      # of Nexo's gated tools, `:tool`, its name and arguments otherwise.
      def approval_subject(chat, tool_call)
        arguments = (tool_call.arguments || {}).to_h.transform_keys(&:to_sym)
        tool = chat.tools[tool_call.qualified_name.to_sym] if chat.respond_to?(:tools)
        return tool.approval_subject(arguments) if tool.is_a?(Nexo::Approvable)

        [:tool, tool_call.name.to_s, arguments]
      end

      # Answers `question` from `answers` when it holds one. `false` declines it.
      def answer(question, answers)
        key = Nexo::InputRequired.key_for(question)
        return false unless answers.key?(key)

        value = answers[key]
        case value
        when false, nil then question.decline
        when Hash then question.answer(**value.transform_keys(&:to_sym))
        else question.answer(value)
        end
        true
      end

      # The chat's token counts and cost so far, or nil for a chat double.
      def usage_of(chat)
        return unless chat.respond_to?(:tokens) && chat.respond_to?(:cost)

        {tokens: chat.tokens.to_h, cost: chat.cost.total}
      rescue
        nil
      end

      # Emits `:usage` with what this prompt added: token counts by kind and the
      # cost, which is nil when `ruby_llm` has no price for the model.
      def report_usage(chat, before, &on_event)
        return unless on_event

        after = usage_of(chat) or return
        tokens = after[:tokens].to_h { |kind, count| [kind, count.to_i - before[:tokens][kind].to_i] }
          .reject { |_, count| count.zero? }
        cost = after[:cost] && (after[:cost] - before[:cost].to_f)
        on_event.call(:usage, {tokens: tokens, cost: cost})
      rescue
        nil
      end
    end
  end
end
