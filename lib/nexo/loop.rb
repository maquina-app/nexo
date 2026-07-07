# frozen_string_literal: true

module Nexo
  # The loop seam: the engine that drives one prompt to completion. Swapping the
  # loop swaps *how* the agent's turns are run — the plain provider-neutral
  # +ruby_llm+ tool loop, or an opt-in vendor-tuned backend — by constructor
  # injection, with no change to the agent class.
  #
  # A loop implements the contract below. The base class raises so an incomplete
  # subclass fails loudly. The optional +&on_event+ block, when given, is called
  # with +(type, payload)+ as the run progresses (e.g. +:tool_call+,
  # +:tool_result+, +:done+) — observability only; it never steers the run.
  #
  # See Loops::RubyLLM (default, provider-neutral) and Loops::AgentSDK
  # (opt-in, Anthropic-oriented).
  class Loop
    # Runs +prompt+ through +agent+ and returns the final response. +max_turns+
    # is a hint a backend may enforce as a hard cap (AgentSDK) or expose only as
    # observability (RubyLLM — see the turn-cap caveat in the README).
    def run(agent:, prompt:, max_turns: 25, &on_event)
      raise NotImplementedError
    end
  end
end
