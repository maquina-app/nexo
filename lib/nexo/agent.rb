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

      # Declares the skills attached to this agent. With no args it returns the
      # configured list (default +[]+); with args it records the names. Follows the
      # same class-ivar convention as the macros above.
      #
      #   class TriageAgent < Nexo::Agent
      #     model ENV.fetch("NEXO_MODEL")
      #     skills :triage          # one macro, no loader setup
      #   end
      def skills(*names)
        names.empty? ? (@skills || []) : (@skills = names)
      end
    end

    # The set of tool names handed to an opt-in backend that ships its own tools
    # (e.g. {Loops::AgentSDK}). The default {Loops::RubyLLM} ignores this — it
    # uses the agent's own sandbox-backed tools instead.
    ALLOWED_TOOLS = %w[Read Write Edit Bash Glob Grep].freeze

    # Maps Nexo's permission modes onto AgentSDK's own permission vocabulary,
    # consumed by {Loops::AgentSDK}. +:ask+ maps to +:default+ on purpose: human
    # gating stays in Nexo's own +on_ask+ path and is not delegated to the SDK.
    PERMISSION_MODE_MAP = {
      read_only: :default,
      auto: :bypass_permissions,
      ask: :default
    }.freeze

    attr_reader :cwd, :model, :sandbox, :permissions, :instructions, :loop

    # Every argument is optional; each resolves arg -> class macro -> config.
    # Symbol shorthands (:virtual/:local, :read_only/:auto/:ask) and pre-built
    # Sandbox/Permissions instances are both accepted. +loop:+ injects the engine
    # that drives a prompt — the provider-neutral {Loops::RubyLLM} by default, or
    # an opt-in backend like {Loops::AgentSDK}.
    def initialize(cwd: Dir.pwd, model: nil, sandbox: nil, permissions: nil, loop: Loops::RubyLLM.new)
      @cwd = cwd
      @model = model || self.class.model || Nexo.config.default_model
      if @model.nil?
        raise ConfigurationError,
          "no model set — use the `model` macro, pass model:, or set Nexo.config.default_model"
      end

      @sandbox = resolve_sandbox(sandbox || self.class.sandbox)
      @permissions = resolve_permissions(permissions || self.class.permissions)
      @instructions = self.class.instructions
      @loop = loop
    end

    # Builds a configured RubyLLM::Chat with the four sandbox-backed tools
    # attached as instances bound to this agent's sandbox and permissions, then
    # layers on the instructions of every declared skill.
    def chat
      c = RubyLLM.chat(model: @model)
      c = c.with_instructions(@instructions) if @instructions
      c.with_tools(
        Tools::ReadFile.new(sandbox: @sandbox, permissions: @permissions),
        Tools::WriteFile.new(sandbox: @sandbox, permissions: @permissions),
        Tools::Shell.new(sandbox: @sandbox, permissions: @permissions),
        Tools::Glob.new(sandbox: @sandbox, permissions: @permissions)
      )
      apply_skills(c)
      c
    end

    # Runs one prompt through the agent by delegating to the injected loop. The
    # loop body that used to live here is now in {Loops::RubyLLM} (the default),
    # so swapping +loop:+ swaps the engine without touching this class. The
    # optional +&on_event+ block receives +(type, payload)+ progress events.
    def prompt(text, max_turns: 25, &on_event)
      @loop.run(agent: self, prompt: text, max_turns: max_turns, &on_event)
    end

    # The agent's Nexo permission mode mapped onto an opt-in backend's own
    # permission vocabulary (see {PERMISSION_MODE_MAP}). Consumed by
    # {Loops::AgentSDK}; the default {Loops::RubyLLM} does its gating inside the
    # sandbox-backed tools and ignores this.
    def permission_mode
      PERMISSION_MODE_MAP.fetch(@permissions.mode, :default)
    end

    # The tool names handed to an opt-in backend that ships its own tools.
    def allowed_tools
      ALLOWED_TOOLS
    end

    private

    # Attaches each declared skill's instructions to +chat+, after the
    # sandbox-backed tools and on top of the agent's own instructions, in
    # declaration order (deterministic). A skill contributes instructions only;
    # it ships no independent tools (its scripts/references are reached through the
    # already-gated sandbox tools), so attaching a skill never widens what the
    # agent can do. +append: true+ adds an extra system message rather than
    # replacing the base instructions.
    def apply_skills(chat)
      self.class.skills.each do |name|
        skill = Skills.find(name)
        chat.with_instructions(skill.content, append: true)
      end
    end

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
