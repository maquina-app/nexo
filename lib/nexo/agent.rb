# frozen_string_literal: true

module Nexo
  # The DSL that composes a model, a sandbox, permissions, and instructions into
  # a working tool-using agent. Subclass it and declare the pieces with class
  # macros, then call +#prompt+:
  #
  #   class CodeReviewer < Nexo::Agent
  #     model       ENV.fetch("NEXO_MODEL")
  #     sandbox     :local
  #     permissions :read_only
  #     instructions "You are a careful code reviewer."
  #   end
  #
  #   CodeReviewer.new(cwd: "/path/to/repo").prompt("Review the auth module")
  #
  # No sandbox, permission, or tool object is instantiated by hand. Defaults are
  # safe: +:virtual+ sandbox + +:read_only+ permissions unless overridden.
  class Agent
    class << self
      # Each macro is a reader with no argument and a writer with one. Unset
      # +sandbox+/+permissions+ fall back to the harness-wide config defaults.
      def model(value = nil)
        value.nil? ? @model : (@model = value)
      end

      def sandbox(value = nil)
        value.nil? ? (@sandbox || Nexo.config.default_sandbox) : (@sandbox = value)
      end

      def permissions(value = nil)
        value.nil? ? (@permissions || Nexo.config.default_permissions) : (@permissions = value)
      end

      def instructions(value = nil)
        value.nil? ? @instructions : (@instructions = value)
      end
    end

    attr_reader :cwd, :model, :sandbox, :permissions, :instructions

    # Every argument is optional; each resolves arg -> class macro -> config.
    # Symbol shorthands (:virtual/:local, :read_only/:auto/:ask) and pre-built
    # Sandbox/Permissions instances are both accepted.
    def initialize(cwd: Dir.pwd, model: nil, sandbox: nil, permissions: nil)
      @cwd = cwd
      @model = model || self.class.model || Nexo.config.default_model
      if @model.nil?
        raise ConfigurationError,
          "no model set — use the `model` macro, pass model:, or set Nexo.config.default_model"
      end

      @sandbox = resolve_sandbox(sandbox || self.class.sandbox)
      @permissions = resolve_permissions(permissions || self.class.permissions)
      @instructions = self.class.instructions
    end

    # Builds a configured RubyLLM::Chat with the four sandbox-backed tools
    # attached as instances bound to this agent's sandbox and permissions.
    def chat
      c = RubyLLM.chat(model: @model)
      c = c.with_instructions(@instructions) if @instructions
      c.with_tools(
        Tools::ReadFile.new(sandbox: @sandbox, permissions: @permissions),
        Tools::WriteFile.new(sandbox: @sandbox, permissions: @permissions),
        Tools::Shell.new(sandbox: @sandbox, permissions: @permissions),
        Tools::Glob.new(sandbox: @sandbox, permissions: @permissions)
      )
      c
    end

    # Runs one prompt through the agent. For Spec 1 the loop logic lives here and
    # is just +chat.ask+; Spec 4 extracts it behind +Loops::RubyLLM+. The
    # +&on_event+ block is accepted now (reserving the signature) but unused.
    def prompt(text, &on_event)
      chat.ask(text)
    end

    private

    def resolve_sandbox(value)
      return value if value.is_a?(Sandbox)

      case value
      when :virtual then Sandboxes::Virtual.new
      when :local then Sandboxes::Local.new(cwd: @cwd)
      else raise ConfigurationError, "unknown sandbox: #{value.inspect}"
      end
    end

    def resolve_permissions(value)
      return value if value.is_a?(Permissions)

      case value
      when :read_only then Permissions.new(mode: :read_only)
      when :auto then Permissions.new(mode: :auto, allow: %i[read glob write shell])
      when :ask then Permissions.new(mode: :ask) # pass a Permissions with on_ask for a real gate
      else raise ConfigurationError, "unknown permissions: #{value.inspect}"
      end
    end
  end
end
