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

      # Opt out of ruby_llm's models.json registry validation for this agent so
      # it can run unregistered models (Ollama tags, self-hosted, brand-new
      # releases). Boolean opt-in: because +nil?+ still distinguishes read from
      # write, +assume_model_exists false+ is an explicit write (sets +false+),
      # not a read. Unset reads as +false+, keeping registry validation on.
      def assume_model_exists(value = nil)
        value.nil? ? (@assume_model_exists || false) : (@assume_model_exists = value)
      end

      # The provider symbol/string (e.g. +:ollama+) passed straight through to
      # +RubyLLM.chat+. Required whenever +assume_model_exists+ is set, since
      # ruby_llm cannot infer a provider once the registry lookup is skipped.
      # Unset resolves to +nil+.
      def provider(value = nil)
        value.nil? ? @provider : (@provider = value)
      end

      # The sandbox macro. With no argument it reads the configured value
      # (falling back to the harness-wide default). With a bare value it stores a
      # symbol/instance as before; with keywords it stores an options Hash
      # (+{ type: value, **opts }+) resolved by {Nexo::Sandboxes.resolve} — e.g.
      # +sandbox :docker, image: "node:22-slim", binds: {...}+.
      def sandbox(value = nil, **opts)
        return @sandbox || Nexo.config.default_sandbox if value.nil? && opts.empty?

        @sandbox = opts.empty? ? value : {type: value, **opts}
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

      # Declares an MCP server for this agent (Spec 6). Accumulating: multiple
      # +mcp+ lines are collected. With no args (+name+ nil and +opts+ empty) it
      # reads the list (default +[]+); otherwise it appends the friendly,
      # transport-shaped config consumed by {Nexo::MCP.build}.
      #
      #   class InboxDigest < Nexo::Agent
      #     model ENV.fetch("NEXO_MODEL")
      #     mcp :gmail, transport: :stdio, command: "npx", args: %w[-y srv-gmail]
      #     mcp :fetch, transport: :sse,   url: "http://localhost:8080/sse"
      #   end
      def mcp(name = nil, **opts)
        return @mcp || [] if name.nil? && opts.empty?

        (@mcp ||= []) << opts.merge(name: name)
      end

      # The MCP tool-name allow-list threaded into this agent's {Permissions} (see
      # +mcp_allow:+ in {#resolve_permissions}). Exact tool-name match only — no
      # globs. Same read-vs-write convention as {skills}: with args it records the
      # flattened names as strings; with none it reads the list (default +[]+).
      def mcp_allow(*names)
        names.empty? ? (@mcp_allow || []) : (@mcp_allow = names.flatten.map(&:to_s))
      end

      # The host allow-list scoping this agent's {Nexo::Tools::Fetch} (Spec 9).
      # Subdomain-aware, exact-host-suffix matching only — no globs. Same
      # read-vs-write convention as {mcp_allow}: with args it records the flattened
      # hosts as strings; with none it reads the list (default +[]+).
      #
      # Declaring +fetch_allow+ only SCOPES hosts — it does not grant the +:fetch+
      # capability, which is default-denied like +:shell+. An agent that wants
      # egress must also run under +:auto+ or carry an explicit
      # +Permissions.new(mode: :read_only, allow: %i[read glob fetch])+. Both locks
      # must open before a fetch happens.
      def fetch_allow(*hosts)
        hosts.empty? ? (@fetch_allow || []) : (@fetch_allow = hosts.flatten.map(&:to_s))
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

    attr_reader :cwd, :model, :provider, :assume_model_exists, :sandbox, :permissions, :instructions, :loop

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

      @assume_model_exists = self.class.assume_model_exists
      @provider = self.class.provider
      if @assume_model_exists && @provider.nil?
        raise ConfigurationError,
          "assume_model_exists is set but no provider given — add the `provider` macro (e.g. `provider :ollama`)"
      end

      @sandbox = resolve_sandbox(sandbox || self.class.sandbox)
      @permissions = resolve_permissions(permissions || self.class.permissions)
      @instructions = self.class.instructions
      @loop = loop
    end

    # Builds a configured chat with the four sandbox-backed tools attached as
    # instances bound to this agent's sandbox and permissions, then layers on the
    # instructions of every declared skill.
    #
    # +base:+ lets a {Nexo::Session} pass a persisted +acts_as_chat+ record
    # (hydrated via ruby_llm's +#to_llm+ delegation) so the very same wiring —
    # instructions, the four sandbox tools, skills, MCP, fetch — is applied onto
    # the continuing thread instead of a fresh chat. When +base+ is nil the path
    # is byte-for-byte the standalone-agent build: a fresh +RubyLLM.chat+. A
    # session therefore changes only *memory/persistence*, never authority or
    # execution — the record supplies the thread, the agent supplies the wiring.
    #
    # Re-applying +@instructions+ on every resume stays idempotent because the
    # persisted-chat +#with_instructions+ (default +append: false+) *replaces* the
    # stored +role: :system+ messages rather than appending, so the thread keeps
    # exactly one copy across resumes (VERIFIED, ruby_llm 1.16.0).
    def chat(base: nil)
      c = base || RubyLLM.chat(**chat_model_options)
      c = c.with_instructions(@instructions) if @instructions
      # Self-describing sandbox (R1): inject after the agent's own instructions
      # and before skills, only when the sandbox describes itself.
      if @sandbox.instructions
        c = c.with_instructions(@sandbox.instructions, append: true)
      end

      # One ReadTracker per chat, shared by ReadFile (records) and WriteFile
      # (enforces the read-before-write + stale guard) — R4.
      tracker = ReadTracker.new
      tools = [
        Tools::ReadFile.new(sandbox: @sandbox, permissions: @permissions, tracker: tracker),
        Tools::WriteFile.new(sandbox: @sandbox, permissions: @permissions, tracker: tracker),
        Tools::Glob.new(sandbox: @sandbox, permissions: @permissions)
      ]
      # Attach Shell only when the sandbox can actually run one (R2), so a
      # :virtual agent stops advertising a tool it can never run.
      if @sandbox.supports?(:shell)
        tools << Tools::Shell.new(sandbox: @sandbox, permissions: @permissions)
      end
      c.with_tools(*tools)
      apply_skills(c)
      apply_mcp(c)
      apply_fetch(c)
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

    # Releases any MCP server connections held by this agent instance. Clients are
    # memoized on the instance and reused across prompts (Spec 6 lifecycle default),
    # so a long-lived agent holding stdio/SSE servers should call +#close+ when
    # done. Idempotent: safe to call with no MCP servers attached or more than once.
    #
    # VERIFY (Group 0, ruby_llm-mcp 1.0.0): the client teardown method is +#stop+
    # (guarded by +respond_to?+, falling back to +#close+ for other client shapes).
    def close
      @mcp_clients&.each do |client|
        if client.respond_to?(:stop)
          client.stop
        elsif client.respond_to?(:close)
          client.close
        end
      end
      @mcp_clients = nil
    end

    private

    # Builds the +RubyLLM.chat+ options conditionally so the default agent's
    # call is byte-for-byte what it was before this feature: +{model: @model}+.
    # +provider+ is added only when resolved; +assume_model_exists: true+ only
    # when opted in (never passed as +false+).
    def chat_model_options
      opts = {model: @model}
      opts[:provider] = @provider if @provider
      opts[:assume_model_exists] = true if @assume_model_exists
      opts
    end

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

    # Lazily connects the declared MCP servers and attaches their tools, each
    # wrapped in a {MCP::GatedTool} so every invocation is authorized through this
    # agent's {Permissions} first. Attached after the four sandbox tools and the
    # skills, so MCP tools fire the chat's +before_tool_call+/+after_tool_result+
    # callbacks (wired in {Loops::RubyLLM}) and appear in the run's event log with
    # no extra wiring. Returns early when no server is declared.
    #
    # Clients are built once and memoized on the instance (Spec 6 lifecycle
    # default): the +ruby_llm-mcp+ client connects on construction and is reusable
    # across prompts, so subsequent +#chat+ calls reuse the live connections until
    # {#close}. VERIFY (Group 0): tools accessor is +client.tools+ (an Array).
    def apply_mcp(chat)
      return if self.class.mcp.empty?

      @mcp_clients ||= self.class.mcp.map { |cfg| Nexo::MCP.build(**cfg) }
      gated = @mcp_clients.flat_map(&:tools).map do |tool|
        Nexo::MCP::GatedTool.new(tool: tool, permissions: @permissions)
      end
      chat.with_tools(*gated) unless gated.empty?
    end

    # Attaches a single {Nexo::Tools::Fetch} scoped to the agent's +fetch_allow+
    # hosts (Spec 9). Returns early when no host is declared, so an agent that never
    # calls +fetch_allow+ gets no fetch tool. Attached right after +apply_mcp+ so
    # the tool participates in the chat's +before_tool_call+/+after_tool_result+
    # event stream (wired in {Loops::RubyLLM}) with no extra wiring. The +:fetch+
    # capability itself is gated through {Permissions#authorize!} at call time — the
    # allow-list only scopes hosts, it is not the capability grant.
    def apply_fetch(chat)
      return if self.class.fetch_allow.empty?

      chat.with_tools(
        Tools::Fetch.new(sandbox: @sandbox, permissions: @permissions, allow_hosts: self.class.fetch_allow)
      )
    end

    # Resolves this agent's sandbox declaration via the shared resolver (Spec 15),
    # passing the agent's instance +@cwd+ as the host working directory (used only
    # by +:local+; container tiers keep their own +/workspace+ default).
    def resolve_sandbox(value) = Sandboxes.resolve(value, cwd: @cwd)

    def resolve_permissions(value)
      # A user-supplied Permissions sets its own mcp_allow: — leave it untouched.
      return value if value.is_a?(Permissions)

      # Thread the class-level mcp_allow into each symbol branch (Spec 6) so the
      # MCP capability axis is populated alongside the sandbox axis.
      allow = self.class.mcp_allow
      case value
      when :read_only then Permissions.new(mode: :read_only, mcp_allow: allow)
      when :auto then Permissions.new(mode: :auto, allow: %i[read glob write shell fetch], mcp_allow: allow)
      when :ask then Permissions.new(mode: :ask, mcp_allow: allow) # pass a Permissions with on_ask for a real gate
      else raise ConfigurationError, "unknown permissions: #{value.inspect}"
      end
    end
  end
end
