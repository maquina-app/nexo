# frozen_string_literal: true

module Nexo
  # The DSL that composes a model, a sandbox, permissions, and instructions into
  # a working tool-using agent. Subclass it and declare the pieces with class
  # macros, then call `#prompt`:
  #
  # ```ruby
  # class CodeReviewer < Nexo::Agent
  #   model       ENV.fetch("NEXO_MODEL")
  #   sandbox     :local
  #   permissions :read_only
  #   instructions "You are a careful code reviewer."
  # end
  #
  # CodeReviewer.new(cwd: "/path/to/repo").prompt("Review the auth module")
  # ```
  #
  # No sandbox, permission, or tool object is instantiated by hand. Defaults are
  # safe: `:virtual` sandbox + `:read_only` permissions unless overridden.
  class Agent
    # The class-level ivars every macro reads/writes. Copied to a subclass in
    # .inherited so `class Child < ConfiguredAgent; end` keeps the parent's
    # configuration instead of silently resetting to defaults.
    CONFIG_IVARS = %i[
      @model @assume_model_exists @provider @sandbox @permissions @instructions
      @skills @mcp @mcp_allow @fetch_allow @search_backend @requires @produces @tools
      @context_budget
    ].freeze

    class << self
      # Carries the parent's macro configuration onto a subclass. Arrays/Hashes are
      # duped so a subclass extending an accumulating macro (e.g. a second `mcp`
      # line) never mutates the parent's collection; scalars and shared config
      # instances (a class-level Permissions) are copied by reference.
      def inherited(subclass)
        super
        CONFIG_IVARS.each do |ivar|
          next unless instance_variable_defined?(ivar)

          value = instance_variable_get(ivar)
          value = value.dup if value.is_a?(Array) || value.is_a?(Hash)
          subclass.instance_variable_set(ivar, value)
        end
      end

      # Each macro is a reader with no argument and a writer with one. Unset
      # `sandbox`/`permissions` fall back to the harness-wide config defaults.
      def model(value = nil)
        value.nil? ? @model : (@model = value)
      end

      # Opt out of ruby_llm's models.json registry validation for this agent so
      # it can run unregistered models (Ollama tags, self-hosted, brand-new
      # releases). Boolean opt-in: because `nil?` still distinguishes read from
      # write, `assume_model_exists false` is an explicit write (sets `false`),
      # not a read. Unset reads as `false`, keeping registry validation on.
      def assume_model_exists(value = nil)
        value.nil? ? (@assume_model_exists || false) : (@assume_model_exists = value)
      end

      # The provider symbol/string (e.g. `:ollama`) passed straight through to
      # `RubyLLM.chat`. Required whenever `assume_model_exists` is set, since
      # ruby_llm cannot infer a provider once the registry lookup is skipped.
      # Unset resolves to `nil`.
      def provider(value = nil)
        value.nil? ? @provider : (@provider = value)
      end

      # The sandbox macro. With no argument it reads the configured value
      # (falling back to the harness-wide default). With a bare value it stores a
      # symbol/instance as before; with keywords it stores an options Hash
      # (`{ type: value, **opts }`) resolved by Nexo::Sandboxes.resolve — e.g.
      # `sandbox :docker, image: "node:22-slim", binds: {...}`.
      def sandbox(value = nil, **opts)
        return @sandbox || Nexo.config.default_sandbox if value.nil? && opts.empty?

        @sandbox = opts.empty? ? value : {type: value, **opts}
      end

      # The permissions macro. With no argument it reads the configured value
      # (falling back to the harness-wide default, `:read_only`); with a value it
      # records the mode symbol or a pre-built Permissions instance.
      def permissions(value = nil)
        value.nil? ? (@permissions || Nexo.config.default_permissions) : (@permissions = value)
      end

      # The instructions macro. With no argument it reads the stored system
      # prompt (default `nil`); with a value it records it.
      def instructions(value = nil)
        value.nil? ? @instructions : (@instructions = value)
      end

      # Keeps tool results within shares of the model's context window — a
      # pass-through to `ruby_llm`'s `Chat#with_context_budget`. With no argument
      # it reads the declared budget (default `nil`: `ruby_llm`'s own
      # `config.context_budget`, which is off unless you set it).
      #
      # ```ruby
      # class Researcher < Nexo::Agent
      #   context_budget per_result: 0.25, per_request: 0.7
      # end
      # ```
      #
      # `per_result:` cuts a single tool result longer than that share and tells
      # the model to ask for less; `per_request:` leaves the oldest tool results
      # out of a request that would exceed that share. Both need the model's
      # context window, which `ruby_llm` knows only for models in its registry —
      # for a local or unregistered model pass `window:` (tokens), or the budget
      # does nothing and `ruby_llm` warns once. This bounds what ANY tool returns,
      # including MCP tools and tools of your own; OutputTruncator still bounds
      # shell output by lines, with or without a known window.
      def context_budget(budget = nil, **shares)
        return @context_budget if budget.nil? && shares.empty?

        @context_budget = (budget || {}).to_h.merge(shares)
      end

      # Declares the skills attached to this agent. With no args it returns the
      # configured list (default `[]`); with args it ACCUMULATES the names
      # (deduped), so multiple `skills` lines add up instead of the last one
      # silently replacing the earlier ones — consistent with `mcp`.
      #
      # ```ruby
      # class TriageAgent < Nexo::Agent
      #   model ENV.fetch("NEXO_MODEL")
      #   skills :triage          # one macro, no loader setup
      #   skills :formatting      # adds to :triage, does not replace it
      # end
      # ```
      def skills(*names)
        names.empty? ? (@skills || []) : (@skills = ((@skills || []) + names).uniq)
      end

      # What this agent needs from whatever sandbox it runs in — checked once,
      # before the first turn, against Sandbox#environment:
      #
      # ```ruby
      # class Publisher < Nexo::Agent
      #   skills :dashboard_designer
      #   requires commands: {"ruby" => ">= 3.1"}, locale: :utf8
      # end
      # ```
      #
      # Declared HERE, in Nexo's own vocabulary, rather than in the skill file:
      # whoever wires an agent to a sandbox is the only person who can *fix* a
      # gap, so the declaration and the fix live in the same place. A skill states
      # its needs in prose via `compatibility:`, which is the spec's field for it
      # and is aimed at a human or a model.
      #
      # `commands:` maps a command that must be on `PATH` to a version constraint
      # — a Gem::Requirement string (`">= 3.1"`) or `"*"` for "any version". A
      # command whose version cannot be read (busybox `sh` prints none) satisfies
      # any constraint by being present: an unreadable version is not evidence of
      # a wrong one. `locale:` takes `:utf8` (any UTF-8 locale — the useful case)
      # or an exact String.
      #
      # Deliberately coarse, and never packages: gems, wheels and npm modules
      # belong to the image, not here (see Sandbox#environment).
      def requires(commands: nil, locale: nil)
        return @requires if commands.nil? && locale.nil?

        @requires = {commands: commands || {}, locale: locale}
      end

      # The artifacts this agent produces — sandbox paths, or globs, that a
      # workflow copies out of the sandbox and records on the run as soon as the
      # agent finishes:
      #
      # ```ruby
      # class Publisher < Nexo::Agent
      #   produces "dashboard.html", "digest.json", "out/*.csv"
      # end
      # ```
      #
      # Accumulating and deduped, like `skills`: an agent may produce many
      # artifacts, and several `produces` lines add up rather than replacing.
      #
      # This is the agent's OUTPUT, not a template. Workflow#artifact's `from:`
      # mode renders ERB and is only ever for files you wrote; what an agent
      # produces is model output and is copied verbatim (Workflow#artifact `path:`).
      #
      # Declared rather than inferred because a sweep of the sandbox would also
      # collect staged skill scripts, templates and scratch files — and because
      # naming outputs is the only honest way for an agent to say it produced
      # nothing. A declared artifact that is absent when the agent finishes is
      # skipped, not fatal.
      def produces(*names)
        names.empty? ? (@produces || []) : (@produces = ((@produces || []) + names).uniq)
      end

      # Declares tools of your own for this agent. Accumulating, like `skills`.
      # With no arguments it reads the declarations (default `[]`).
      #
      # ```ruby
      # class Archivist < Nexo::Agent
      #   tools Today, SumPayments                 # pure helpers: no gate
      #   tools ArchiveRun, capability: :write     # gated like Nexo's write tool
      #   tools ->(agent) { Lookup.new(root: agent.cwd) }
      # end
      # ```
      #
      # Each entry is a `RubyLLM::Tool` class (instantiated with no arguments), an
      # instance, or a lambda taking the agent and returning one — or an Array of
      # them, for an agent whose tools depend on how it was built.
      #
      # `capability:` names what the tool does in Nexo's terms — `:read`, `:write`,
      # `:shell`, `:fetch`, `:search`. The tool is then wrapped in Nexo::GatedTool:
      # the agent's Permissions decide every call exactly as they do for Nexo's
      # own tools (denied under `:read_only`, prompted under `:ask`, suspended
      # under `:approve`), and it is left out of the schema when it could never be
      # authorized. Without `capability:` the tool runs ungated — the right choice
      # only for a tool with no side effects.
      #
      # Declare tools here instead of overriding `#chat` to call `with_tools`: a
      # tool added that way is unknown to Nexo, which warns about it, and refuses
      # it under `Nexo.config.strict_tools`.
      def tools(*list, capability: nil)
        return @tools || [] if list.empty?

        @tools = (@tools || []) + list.flatten.map { |tool| {tool: tool, capability: capability} }
      end

      # Declares an MCP server for this agent (Spec 6). Accumulating: multiple
      # `mcp` lines are collected. With no args (`name` nil and `opts` empty) it
      # reads the list (default `[]`); otherwise it appends the friendly,
      # transport-shaped config consumed by Nexo::MCP.build.
      #
      # ```ruby
      # class InboxDigest < Nexo::Agent
      #   model ENV.fetch("NEXO_MODEL")
      #   mcp :gmail, transport: :stdio, command: "npx", args: %w[-y srv-gmail]
      #   mcp :fetch, transport: :sse,   url: "http://localhost:8080/sse"
      # end
      # ```
      def mcp(name = nil, **opts)
        return @mcp || [] if name.nil? && opts.empty?

        (@mcp ||= []) << opts.merge(name: name)
      end

      # The MCP tool-name allow-list threaded into this agent's Permissions (see
      # `mcp_allow:` in #resolve_permissions). Exact tool-name match only — no
      # globs. Like `skills`, with args it ACCUMULATES the flattened names as
      # strings (deduped); with none it reads the list (default `[]`).
      def mcp_allow(*names)
        names.empty? ? (@mcp_allow || []) : (@mcp_allow = ((@mcp_allow || []) + names.flatten.map(&:to_s)).uniq)
      end

      # The host allow-list scoping this agent's Nexo::Tools::Fetch (Spec 9).
      # Subdomain-aware, exact-host-suffix matching only — no globs. Like
      # `skills`/`mcp_allow`, with args it ACCUMULATES the flattened hosts as
      # strings (deduped); with none it reads the list (default `[]`).
      #
      # Declaring `fetch_allow` only SCOPES hosts — it does not grant the `:fetch`
      # capability, which is default-denied like `:shell`. An agent that wants
      # egress must also run under `:auto` or carry an explicit
      # `Permissions.new(mode: :read_only, allow: %i[read glob fetch])`. Both locks
      # must open before a fetch happens.
      def fetch_allow(*hosts)
        hosts.empty? ? (@fetch_allow || []) : (@fetch_allow = ((@fetch_allow || []) + hosts.flatten.map(&:to_s)).uniq)
      end

      # The host-injected search backend for this agent's Nexo::Tools::WebSearch
      # (Spec 19). Reader/writer by nil-check, matching the `model` macro
      # convention. Any object responding to `search(query, **opts)` that
      # returns an Enumerable of `{title:, url:, snippet:}` rows works — Nexo ships
      # no backend. Unset reads as `nil`, in which case no search tool is attached.
      #
      # Declaring `search_backend` does not grant the `:search` capability, which is
      # default-denied like `:fetch`/`:shell`. An agent that wants web discovery must
      # also run under `:auto` or carry an explicit `allow: [..., :search]`.
      def search_backend(obj = nil)
        obj.nil? ? @search_backend : (@search_backend = obj)
      end
    end

    # The resolved per-instance configuration (arg → class macro → config): the
    # working directory, model, provider, `assume_model_exists` flag, the resolved
    # Sandbox and Permissions, the system instructions, and the injected Loop.
    attr_reader :cwd, :model, :provider, :assume_model_exists, :sandbox, :permissions, :instructions, :loop

    # Every argument is optional; each resolves arg -> class macro -> config.
    # Symbol shorthands (:virtual/:local, :read_only/:auto/:ask/:approve) and
    # pre-built Sandbox/Permissions instances are both accepted. `loop:` injects
    # the engine that drives a prompt — the provider-neutral Loops::RubyLLM by
    # default, or a backend of your own.
    #
    # `decisions:` (0.14, default `nil`) are the per-call approval answers for an
    # `:approve` gate — a Hash of Permissions::approval_key → `true`/`false`. A
    # call found there runs or is denied; any other call raises
    # Nexo::ApprovalRequired. They only supply *answers* to an already-`:approve`
    # gate — they never widen capability. Workflow#run_agent passes the approvals
    # recorded on the run. `decision:` is the deprecated global form (one
    # `{approved:}` answer for every gated call).
    def initialize(cwd: Dir.pwd, model: nil, sandbox: nil, permissions: nil, decision: nil, decisions: nil,
      loop: Loops::RubyLLM.new)
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

      # The agent owns (and so closes) its sandbox only when it resolved one from
      # its own config. A sandbox injected via `sandbox:` (e.g. Workflow#run_agent
      # sharing the run's sandbox) is BORROWED — closing it would strand the owner.
      @owns_sandbox = sandbox.nil?
      @sandbox = resolve_sandbox(sandbox || self.class.sandbox)
      @permissions = resolve_permissions(permissions || self.class.permissions, decision: decision,
        decisions: decisions)
      @instructions = self.class.instructions
      @loop = loop
    end

    # Builds a configured chat with the four sandbox-backed tools attached as
    # instances bound to this agent's sandbox and permissions, then layers on the
    # instructions of every declared skill.
    #
    # `base:` lets a Nexo::Session pass a persisted `acts_as_chat` record
    # (hydrated via ruby_llm's `#to_llm` delegation) so the very same wiring —
    # instructions, the four sandbox tools, skills, MCP, fetch — is applied onto
    # the continuing thread instead of a fresh chat. When `base` is nil the path
    # is byte-for-byte the standalone-agent build: a fresh `RubyLLM.chat`. A
    # session therefore changes only *memory/persistence*, never authority or
    # execution — the record supplies the thread, the agent supplies the wiring.
    #
    # Re-applying `@instructions` on every resume stays idempotent because the
    # persisted-chat `#with_instructions` (default `append: false`) *replaces* the
    # stored `role: :system` messages rather than appending, so the thread keeps
    # exactly one copy across resumes (VERIFIED, ruby_llm 2.2.3).
    def chat(base: nil)
      c = base || RubyLLM.chat(**chat_model_options)
      c = apply_instructions(c)

      # One ReadTracker per chat, shared by ReadFile (records) and WriteFile
      # (enforces the read-before-write + stale guard) — R4.
      tracker = ReadTracker.new
      # A sandbox tool is attached only when the agent could actually use it, on
      # BOTH axes: the sandbox has to support the capability (R2 — a :virtual
      # sandbox has no shell) and the gate must not deny it statically (a
      # :read_only agent can never be authorized for :write or :shell). Otherwise
      # a guaranteed failure sits in the tool schema on every turn and models do
      # try it. This is the same attach-time gating apply_fetch/apply_search
      # already apply; #authorize! stays the actual boundary either way.
      tools = [Tools::ReadFile.new(sandbox: @sandbox, permissions: @permissions, tracker: tracker)]
      unless @permissions.never_allows?(:write)
        tools << Tools::WriteFile.new(sandbox: @sandbox, permissions: @permissions, tracker: tracker)
      end
      tools << Tools::Glob.new(sandbox: @sandbox, permissions: @permissions)
      if @sandbox.supports?(:shell) && !@permissions.never_allows?(:shell)
        tools << Tools::Shell.new(sandbox: @sandbox, permissions: @permissions)
      end
      c.with_tools(*tools)
      apply_host_tools(c)
      apply_mcp(c)
      apply_fetch(c)
      apply_search(c)
      apply_tool_options(c)
      apply_context_budget(c)
      apply_tool_backstop(c)
      c
    end

    # Runs one prompt through the agent by delegating to the injected loop. The
    # loop body that used to live here is now in Loops::RubyLLM (the default),
    # so swapping `loop:` swaps the engine without touching this class. The
    # optional `&on_event` block receives `(type, payload)` progress events.
    def prompt(text, max_turns: 25, &on_event)
      verify_environment!
      @loop.run(agent: self, prompt: text, max_turns: max_turns, &on_event)
    end

    # Checks the agent's declared ::requires against its sandbox, once, before the
    # first turn. A no-op — and zero cost, no probe at all — when nothing is
    # declared, which is the default.
    #
    # Fails BEFORE the model is called, because the alternative is what this
    # exists to prevent: the agent spends turns deciding to run a script, runs it,
    # and gets `sh: ruby: not found` or an Encoding::InvalidByteSequenceError three
    # frames into a JSON parse. One legible sentence naming what is missing and
    # where beats a stack trace after the fact.
    #
    # Raises Nexo::EnvironmentError listing every unmet requirement at once, so a
    # misprovisioned image is fixed in one pass rather than one round trip per
    # missing command.
    def verify_environment!
      return if @environment_verified

      req = self.class.requires
      @environment_verified = true
      return if req.nil?

      missing = unmet_requirements(req, @sandbox.environment)
      return if missing.empty?

      raise Nexo::EnvironmentError,
        "#{self.class} cannot run here: #{missing.join("; ")}. " \
        "Provision the sandbox, or drop the `requires` declaration."
    end

    private

    # The declared requirements this environment does not meet, as human-readable
    # phrases. Reports the probe's own failure first when it could not run at all:
    # "no ruby" and "I never got to look" are different problems with different
    # fixes, and saying the first when the second is true sends the reader to the
    # wrong place.
    def unmet_requirements(req, env)
      return ["could not inspect the sandbox (#{env[:error]})"] if env[:error]

      missing = req[:commands].filter_map do |name, constraint|
        found = env[:commands][name.to_s]
        next "no #{name} on PATH" if found.nil?
        next unless version_short?(found[:version], constraint)

        "#{name} #{found[:version]} does not satisfy #{constraint}"
      end
      missing << locale_complaint(req[:locale], env[:locale]) if locale_unmet?(req[:locale], env[:locale])
      missing
    end

    # Whether a found command's version fails `constraint`. A missing version, an
    # unparseable constraint, or `"*"` all pass: presence is the requirement, and
    # an unreadable version is not evidence of a wrong one.
    def version_short?(version, constraint)
      return false if version.nil? || constraint.nil? || constraint.to_s.strip == "*"

      !Gem::Requirement.new(constraint.to_s).satisfied_by?(Gem::Version.new(version))
    rescue ArgumentError
      false
    end

    # `:utf8` asks for any UTF-8 locale (the only case that comes up in practice);
    # a String asks for that exact locale. An unset locale never satisfies either
    # — that is the container default, and the bug this catches.
    def locale_unmet?(required, actual)
      return false if required.nil?
      return true if actual.nil?

      (required == :utf8) ? !actual.match?(/utf-?8/i) : actual != required.to_s
    end

    def locale_complaint(required, actual)
      want = (required == :utf8) ? "a UTF-8 locale" : "locale #{required}"
      actual.nil? ? "no locale set (needs #{want})" : "locale #{actual} is not #{want}"
    end

    public

    # Releases any MCP server connections held by this agent instance. Clients are
    # memoized on the instance and reused across prompts (Spec 6 lifecycle default),
    # so a long-lived agent holding stdio/SSE servers should call `#close` when
    # done. Idempotent: safe to call with no MCP servers attached or more than once.
    #
    # VERIFIED (ruby_llm 2.2.3): a `RubyLLM::MCP` server is torn down with `#close`,
    # which stops a stdio process and ends an HTTP session.
    def close
      @mcp_clients&.each do |client|
        client.close if client.respond_to?(:close)
      rescue
        # Best-effort teardown: a failing stop on one client must not strand the
        # remaining clients or leave @mcp_clients set (breaking idempotency).
        # Swallow and continue to the next.
      end
      @mcp_clients = nil

      # Release the sandbox too, so a container/remote-backed agent doesn't leak
      # its container/connection when the caller only remembers `close`. Only close
      # a sandbox this agent OWNS (resolved from its own config) — a borrowed one
      # (injected via `sandbox:`, e.g. Workflow#run_agent's shared run sandbox) is
      # the injector's to close. The base Sandbox#close is a no-op, so this is safe
      # and idempotent for :virtual/:local. Best-effort: never raise out of close.
      if @owns_sandbox
        begin
          @sandbox&.close
        rescue
          # Swallow: close must stay idempotent and non-raising.
        end
      end
    end

    private

    # Builds the `RubyLLM.chat` options conditionally so the default agent's
    # call is byte-for-byte what it was before this feature: `{model: @model}`.
    # `provider` is added only when resolved; `assume_model_exists: true` only
    # when opted in (never passed as `false`).
    def chat_model_options
      opts = {model: @model}
      opts[:provider] = @provider if @provider
      opts[:assume_model_exists] = true if @assume_model_exists
      opts
    end

    # Applies the full system-prompt stack to `chat` in deterministic order: the
    # agent's own instructions, then the self-describing sandbox instructions (R1),
    # then each declared skill's body. A skill contributes instructions only — it
    # ships no independent tools (its scripts/references are reached through the
    # already-gated sandbox tools), so attaching one never widens the agent.
    #
    # The FIRST contribution is applied with `append: false` and the rest with
    # `append: true`. On a fresh chat that is byte-for-byte the prior behavior; on
    # a Nexo::Session's persisted, re-hydrated chat the leading `append: false`
    # collapses all prior `role: :system` messages to one before the rest
    # re-append, so N resumes keep exactly ONE copy of the stack — even when the
    # agent declares no `instructions` (the case that previously let skills/sandbox
    # instructions accumulate a fresh copy per resume).
    def apply_instructions(chat)
      texts = []
      texts << @instructions if @instructions
      texts << @sandbox.instructions if @sandbox.instructions
      self.class.skills.each { |name| texts << skill_instructions(Skills.find(name)) }

      texts.each_with_index do |text, i|
        chat = chat.with_instructions(text, append: i.positive?)
      end
      chat
    end

    # One skill's contribution to the system prompt: its body, plus its
    # `compatibility:` frontmatter when set.
    #
    # `compatibility:` is the Agent Skills spec's own field for what a skill needs
    # in order to run ("requires a Ruby interpreter and a UTF-8 locale"), and it is
    # free text by design — the spec deliberately does not make it machine-checkable.
    # Nexo parsed it and then dropped it, so the one place an author can state a
    # requirement never reached the model. That matters now that a skill can ship a
    # script Nexo stages into a sandbox (Skills.materialize): the environment is no
    # longer the author's machine, and the model is the one deciding whether to run
    # the thing.
    #
    # Labelled rather than concatenated, so the model can tell a requirement from an
    # instruction. Absent or blank `compatibility:` contributes nothing, leaving the
    # prompt byte-for-byte as before for every skill that does not set it. `license:`
    # and `allowed-tools:` are deliberately NOT surfaced: the first is prompt noise,
    # and the second would be a second source of truth about what an agent may do,
    # competing with Nexo::Permissions, which is the real gate.
    def skill_instructions(skill)
      body = skill.content.to_s
      compat = skill.compatibility.to_s.strip if skill.respond_to?(:compatibility)
      return body if compat.nil? || compat.empty?

      "#{body}\n\nCompatibility: #{compat}".strip
    end

    # Lazily connects the declared MCP servers and attaches their tools, each
    # wrapped in a MCP::GatedTool so every invocation is authorized through this
    # agent's Permissions first. Attached after the four sandbox tools and the
    # skills, so MCP tools fire the chat's `before_tool_call`/`after_tool_result`
    # callbacks (wired in Loops::RubyLLM) and appear in the run's event log with
    # no extra wiring. Returns early when no server is declared.
    #
    # Servers are built once and memoized on the instance: a `RubyLLM::MCP` server
    # connects on its first request and is reusable across prompts, so subsequent
    # `#chat` calls reuse the live connections until #close.
    #
    # The tools are attached with `with_tools` — NOT `chat.with_mcp(server)` — so
    # each one can be wrapped in the permission gate first. VERIFIED (ruby_llm
    # 2.2.3): `server.tools` is an Array of `RubyLLM::MCP::Tool`. Tools an MCP App
    # reserves for its own UI are left out, as `with_mcp` would.
    def apply_mcp(chat)
      return if self.class.mcp.empty?

      @mcp_clients ||= self.class.mcp.map { |cfg| Nexo::MCP.build(**cfg) }
      gated = @mcp_clients.flat_map(&:tools).select { |tool| attachable_mcp_tool?(tool) }.map do |tool|
        wrap_mcp_tool(Nexo::MCP::GatedTool.new(tool: tool, permissions: @permissions))
      end
      chat.with_tools(*gated) unless gated.empty?
    end

    # Whether an MCP tool is worth attaching: the model may call it, and the gate
    # could authorize it. A tool `:read_only` can never allow is left out of the
    # schema, as a sandbox tool is — it would only cost tokens and a wasted call.
    def attachable_mcp_tool?(tool)
      model_callable?(tool) && !@permissions.never_allows_mcp?(tool.name)
    end

    # Whether the model may call this MCP tool. Only MCP App tools restrict it.
    def model_callable?(tool)
      !tool.respond_to?(:visibility) || tool.visibility.include?(:model)
    end

    # Attaches the tools declared with the `tools` macro. One declared with a
    # `capability:` is wrapped in Nexo::GatedTool, and skipped altogether when the
    # gate could never authorize it.
    def apply_host_tools(chat)
      built = self.class.tools.flat_map do |entry|
        capability = entry[:capability]
        next [] if capability && @permissions.never_allows?(capability)

        build_host_tools(entry[:tool]).map do |tool|
          capability ? Nexo::GatedTool.new(tool: tool, permissions: @permissions, capability: capability) : tool
        end
      end
      chat.with_tools(*built) unless built.empty?
    end

    # A declared tool is a class, an instance, or a lambda taking the agent. The
    # lambda may return several tools, and may return classes.
    def build_host_tools(tool)
      case tool
      when Class then [tool.new]
      when Proc then Array(tool.call(self)).flat_map { |built| build_host_tools(built) }
      else [tool]
      end
    end

    # The fail-closed backstop behind the gate. Every tool Nexo attached is on the
    # chat by now; one `around_tool_call` block lets those run and catches any
    # other — a tool the host added to the chat itself, which no gate ever saw.
    # Under `Nexo.config.strict_tools` such a call is skipped (`ruby_llm` then
    # tells the model the call did not run); otherwise it runs with a one-time
    # warning.
    #
    # This is a backstop, not the gate: a skipped call can only produce
    # `ruby_llm`'s fixed "did not run" text, so the gate that explains itself
    # stays in the tools (VERIFIED, ruby_llm 2.2.3).
    #
    # The block is registered once per chat and reads the known names from the
    # chat, so a Session that rebuilds over the same chat does not stack blocks.
    # It runs on the tool's own thread under tool concurrency; the name set is
    # frozen and only read.
    def apply_tool_backstop(chat)
      return unless chat.respond_to?(:around_tool_call) && chat.respond_to?(:tools)

      chat.instance_variable_set(:@nexo_known_tools, chat.tools.keys.to_set(&:to_s).freeze)
      return if chat.instance_variable_get(:@nexo_backstop)

      chat.instance_variable_set(:@nexo_backstop, true)
      chat.around_tool_call do |tool_call, &run|
        name = tool_call.name.to_s
        if chat.instance_variable_get(:@nexo_known_tools).include?(name)
          run.call
        elsif !Nexo.config.strict_tools
          Nexo.warn_undeclared_tool(name, self.class)
          run.call
        end
      end
    end

    # Applies the harness-wide tool execution settings through
    # `with_tool_options` (ruby_llm 2.x moved them off `with_tools`):
    # Nexo.config.tool_concurrency, where `nil` leaves RubyLLM's own setting
    # alone, and Nexo.config.tool_calls_per_round, where `nil` sets no cap.
    def apply_tool_options(chat)
      return unless chat.respond_to?(:with_tool_options)

      options = {concurrency: Nexo.config.tool_concurrency, calls: Nexo.config.tool_calls_per_round}.compact
      chat.with_tool_options(**options) unless options.empty?
    end

    # Applies the agent's `context_budget` declaration, when there is one.
    def apply_context_budget(chat)
      budget = self.class.context_budget
      chat.with_context_budget(budget) if budget && chat.respond_to?(:with_context_budget)
    end

    # Hook: called once per MCP tool, AFTER it is wrapped in a permission-gating
    # MCP::GatedTool and before it is attached. Returns the tool to attach; the
    # default returns it unchanged.
    #
    # Override to decorate every MCP tool an agent gets — capping an oversized reply,
    # recording timings, redacting a field. A third-party MCP server's response shape
    # is not yours to change, and its tools are attached by the harness rather than by
    # you, so without this seam the only way in was to override the private
    # `#apply_mcp`.
    #
    # ```ruby
    # class MailAgent < Nexo::Agent
    #   mcp :mail, transport: :stdio, command: "apple-mail-mcp"
    # ```
    #
    #     def wrap_mcp_tool(tool)
    #       CappedTool.new(tool: tool, max_chars: 4_000)
    #     end
    #   end
    #
    # A wrapper must keep the duck type the chat relies on — `#name`, `#description`,
    # `#parameters_schema` and `#call`. GatedTool delegates the rest through
    # `method_missing`, so wrappers compose. Gating happens underneath, so a wrapper
    # only ever sees an already-authorized call: wrapping cannot widen what the agent
    # may do.
    def wrap_mcp_tool(tool)
      tool
    end

    # Attaches a single Nexo::Tools::Fetch scoped to the agent's `fetch_allow`
    # hosts (Spec 9). Returns early when no host is declared, so an agent that never
    # calls `fetch_allow` gets no fetch tool. Attached right after `apply_mcp` so
    # the tool participates in the chat's `before_tool_call`/`after_tool_result`
    # event stream (wired in Loops::RubyLLM) with no extra wiring. The `:fetch`
    # capability itself is gated through Permissions#authorize! at call time — the
    # allow-list only scopes hosts, it is not the capability grant.
    def apply_fetch(chat)
      return if self.class.fetch_allow.empty?
      # The allow-list scopes hosts; it is not the capability grant. A gate that
      # can never authorize :fetch gets no tool rather than a guaranteed failure
      # in its schema (see Permissions#never_allows?).
      return if @permissions.never_allows?(:fetch)

      chat.with_tools(
        Tools::Fetch.new(sandbox: @sandbox, permissions: @permissions, allow_hosts: self.class.fetch_allow)
      )
    end

    # Attaches a single Nexo::Tools::WebSearch bound to the agent's injected
    # `search_backend` (Spec 19). Returns early when no backend is declared, so an
    # agent that never calls `search_backend` gets no search tool — existing agents
    # are byte-for-byte unchanged. Attached right after `apply_fetch` so the tool
    # rides the same `before_tool_call`/`after_tool_result` event stream (wired in
    # Loops::RubyLLM) with no extra wiring. The `:search` capability itself is gated
    # through Permissions#authorize! at call time.
    def apply_search(chat)
      backend = self.class.search_backend or return
      return if @permissions.never_allows?(:search)

      chat.with_tools(
        Tools::WebSearch.new(sandbox: @sandbox, permissions: @permissions, backend: backend)
      )
    end

    # Resolves this agent's sandbox declaration via the shared resolver (Spec 15),
    # passing the agent's instance `@cwd` as the host working directory (used only
    # by `:local`; container tiers keep their own `/workspace` default).
    def resolve_sandbox(value) = Sandboxes.resolve(value, cwd: @cwd)

    def resolve_permissions(value, decision: nil, decisions: nil)
      # A user-supplied Permissions sets its own mcp_allow: — leave it untouched.
      # Thread the run's approval answers through a non-mutating copy (Spec 16)
      # so a shared, class-level :approve instance is never clobbered.
      if value.is_a?(Permissions)
        value = value.with_decision(decision) if decision
        value = value.with_decisions(decisions) if decisions
        return value
      end

      # Thread the class-level mcp_allow into each symbol branch (Spec 6) so the
      # MCP capability axis is populated alongside the sandbox axis.
      allow = self.class.mcp_allow
      case value
      when :read_only then Permissions.new(mode: :read_only, mcp_allow: allow)
      when :auto then Permissions.new(mode: :auto, allow: %i[read glob write shell fetch search], mcp_allow: allow)
      when :ask then Permissions.new(mode: :ask, mcp_allow: allow) # pass a Permissions with on_ask for a real gate
      when :approve then Permissions.new(mode: :approve, mcp_allow: allow, decision: decision, decisions: decisions)
      else raise ConfigurationError, "unknown permissions: #{value.inspect}"
      end
    end
  end
end
