# frozen_string_literal: true

module Nexo
  # The `RubyLLM::Agent` an agent's `llm` block is written on.
  #
  # Nexo::Agent does not inherit from `RubyLLM::Agent` — the two build a chat
  # differently (one chat per prompt against one chat per agent) and several
  # macros share a name but not a meaning. It composes it instead: the `llm`
  # block of an agent class is evaluated on a private subclass of this class,
  # and Agent#chat builds every chat through that subclass. Every model option
  # `RubyLLM::Agent` can declare is therefore available to a Nexo agent, with
  # nothing re-implemented here:
  #
  # ```ruby
  # class Reviewer < Nexo::Agent
  #   model "claude-sonnet-5-5"
  #
  #   llm do
  #     thinking effort: :high
  #     temperature 0.2
  #     fallbacks "claude-haiku-5-5"
  #   end
  # end
  # ```
  #
  # What Nexo already owns is refused inside the block, with the macro to use in
  # its place: the model, the instructions, and everything that would put a tool
  # on the chat without passing the permission gate.
  class ModelOptions < ::RubyLLM::Agent
    # Declarations refused inside an `llm` block, each with what to use.
    OWNED = {
      model: "the `model`, `provider` and `assume_model_exists` macros",
      instructions: "the `instructions` macro",
      tools: "the `tools` macro, which puts a tool behind the permission gate",
      mcp: "the `mcp` macro, which puts each MCP tool behind the permission gate",
      skills: "the `skills` macro",
      provider_tools: "nothing — a provider-side tool runs outside the permission gate",
      file_store: "the `file_tools` macro, which gates the same tools",
      code_execution: "a sandbox with a shell — `run_code` runs outside the permission gate"
    }.freeze

    # These two have no reader form: any call declares.
    ALWAYS_DECLARES = %i[file_store code_execution].freeze

    class << self
      OWNED.each do |name, instead|
        define_method(name) do |*args, **options, &block|
          reading = args.empty? && options.empty? && block.nil? && !ALWAYS_DECLARES.include?(name)
          return super() if reading

          raise Nexo::ConfigurationError,
            "`#{name}` cannot be declared inside an `llm` block. Use #{instead}."
        end
      end
    end
  end
end
