# frozen_string_literal: true

module Nexo
  module Loops
    # An opt-in, Anthropic-oriented loop that delegates to +ruby_llm-agent_sdk+'s
    # own engine: native +max_turns+, permission modes, and the SDK's built-in
    # tools. It is NOT the default and is not provider-neutral — choose it
    # explicitly with +loop: Nexo::Loops::AgentSDK.new+ when you are on Anthropic
    # and want the Claude fast path.
    #
    # The trade vs. Loops::RubyLLM: this leans on the SDK's own built-in tools
    # and runs in the host process, so it does NOT execute through Nexo's
    # pluggable sandbox. That is the documented cost of the native +max_turns+
    # hard cap (see the turn-cap caveat in the README).
    #
    # +ruby_llm-agent_sdk+ is a SOFT dependency: it is required lazily inside
    # +#run+ and, when absent, surfaces as a Nexo::MissingDependencyError with
    # install guidance — +require "nexo"+ without the gem never raises.
    #
    # VERIFY-on-install: the gem is not installed in this environment, so
    # +RubyLLM::AgentSDK.query+'s exact signature and the +:result+ terminal
    # message shape below remain provisional (per references.md). Confirm them
    # against the +ruby_llm-agent_sdk+ README the moment the gem is added and
    # record the result under "Verified APIs".
    class AgentSDK < Nexo::Loop
      def run(agent:, prompt:, max_turns: 25, chat: nil, &on_event)
        unless chat.nil?
          raise Nexo::ConfigurationError,
            "Loops::AgentSDK runs its own in-process loop and cannot continue a persisted Nexo::Session chat — use the default Loops::RubyLLM for sessions."
        end

        load_sdk!

        result = nil
        ::RubyLLM::AgentSDK.query(
          prompt,
          model: agent.model,
          max_turns: max_turns,
          permission_mode: agent.permission_mode, # Nexo mode mapped by the agent
          allowed_tools: agent.allowed_tools # %w[Read Write Edit Bash Glob Grep]
        ) do |message|
          on_event&.call(message.type, message)
          result = message if message.type == :result
        end
        # Emit the contract's terminal :done event (the base Loop advertises
        # :tool_call/:tool_result/:done) so a Workflow#run_agent driving THIS
        # backend records an `agent_done` just like the default loop does. The
        # SDK's INTERMEDIATE event types stay backend-native (:assistant/:result/…)
        # — this loop is opt-in and its per-message vocabulary is the SDK's.
        on_event&.call(:done, result)
        result
      end

      private

      # Lazily loads the opt-in +ruby_llm-agent_sdk+ gem. The rescue wraps ONLY the
      # require (mirroring Skills.load!/MCP.load!), so a LoadError raised from
      # inside the SDK's own +query+ or the caller's block is NOT mislabeled as a
      # missing-gem error.
      def load_sdk!
        require "ruby_llm/agent_sdk" # VERIFY exact require path on install
      rescue LoadError
        raise Nexo::MissingDependencyError,
          "Loops::AgentSDK requires the `ruby_llm-agent_sdk` gem. Add `gem \"ruby_llm-agent_sdk\"` to your Gemfile and run `bundle install`."
      end
    end
  end
end
