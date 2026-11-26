# frozen_string_literal: true

module Nexo
  # The loop seam: the engine that drives one prompt to completion. Swapping the
  # loop swaps *how* the agent's turns are run — the plain provider-neutral
  # `ruby_llm` tool loop, or a backend of your own — by constructor injection,
  # with no change to the agent class.
  #
  # A loop implements the contract below. The base class raises so an incomplete
  # subclass fails loudly. The optional `&on_event` block, when given, is called
  # with `(type, payload)` as the run progresses (e.g. `:tool_call`,
  # `:tool_result`, `:done`) — observability only; it never steers the run.
  #
  # See Loops::RubyLLM, the default and only backend Nexo ships.
  class Loop
    # Runs `prompt` through `agent` and returns the final response. `max_turns`
    # caps how many tool rounds one prompt may run; Loops::RubyLLM enforces it.
    #
    # `chat:` (default `nil`) lets a Nexo::Session inject a hydrated, continuing
    # chat so the loop runs over the persisted thread. It is part of the base
    # contract so every backend accepts it; a backend that cannot continue a
    # chat should reject a non-nil one rather than silently drop the session's
    # memory.
    def run(agent:, prompt:, max_turns: 25, chat: nil, &on_event)
      raise NotImplementedError
    end
  end
end
