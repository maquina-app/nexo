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
      @context_budget @file_tools
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
        subclass.instance_variable_set(:@llm, Class.new(@llm)) if @llm
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

      # Declares model options through `ruby_llm`'s own agent DSL (0.16). The
      # block is evaluated on a private `RubyLLM::Agent` subclass (see
      # ModelOptions) and every chat this agent builds is built through it, so
      # anything `RubyLLM::Agent` can declare about the model works here:
      #
      # ```ruby
      # class Reviewer < Nexo::Agent
      #   model "claude-sonnet-5-5"
      #
      #   llm do
      #     thinking effort: :high
      #     temperature 0.2
      #     fallbacks "claude-haiku-5-5"
      #     schema ReviewSchema
      #   end
      # end
      # ```
      #
      # Several `llm` blocks add up, and a subclass starts from its parent's
      # declarations. What Nexo owns — the model, the instructions, tools, MCP
      # servers, skills — is refused inside the block with a
      # ConfigurationError naming the Nexo macro to use: those are the things
      # the sandbox and the permission gate depend on. With no block it reads
      # the class the declarations live on (`nil` when there are none).
      def llm(&block)
        return @llm unless block

        @llm ||= Class.new(ModelOptions)
        @llm.class_eval(&block)
        @llm
      end

      # Which file tools the agent gets. With no argument it reads the choice
      # (default: Nexo.config.file_tools, which is `:core` since 0.16).
      #
      # * `:core` — `ruby_llm`'s `list_files`, `read_file`, `search_files`,
      #   `write_file` and `edit_file`, over the agent's sandbox (see
      #   SandboxFileStore): editing part of a file, searching contents, and a
      #   read-before-write guard that works on every sandbox.
      # * `:none` — no file tools: for an agent that reaches its files another
      #   way, such as a filesystem MCP server whose tools carry the same names.
      #
      # The tools are behind the permission gate: reading, listing and searching
      # are `:read`, writing and editing are `:write`, and under `:read_only` the
      # writing tools are not attached at all. A path may be relative to the
      # sandbox's working directory or absolute inside it. Nexo's own `ReadFile`,
      # `WriteFile` and `Glob` (`:nexo`) were removed in 0.16.
      def file_tools(value = nil)
        value.nil? ? (@file_tools || Nexo.config.file_tools) : (@file_tools = value)
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
      #
      # `defer: true` (0.16) keeps the tools' definitions out of the model's
      # context until the provider's tool search loads the ones it needs — for a
      # long catalogue. A provider without tool search gets them as ordinary
      # tools. A deferred tool is gated exactly like any other.
      def tools(*list, capability: nil, defer: nil)
        return @tools || [] if list.empty?

        @tools = (@tools || []) + list.flatten.map { |tool| {tool: tool, capability: capability, defer: defer} }
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
      #
      # Two options are Nexo's own (0.16): `defer: true` keeps this server's tool
      # definitions out of the model's context until the provider's tool search
      # asks for them, and `resources: true` attaches `list_mcp_resources` and
      # `read_mcp_resource` (see MCP::ReadResource) for what the server offers to
      # read. Both resource tools are gated like any MCP tool.
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

    # The answers this agent was given for questions its tools ask (0.16) — a
    # Hash of Nexo::InputRequired.key_for → value. Empty unless `answers:` was
    # passed.
    attr_reader :answers

    # Every argument is optional; each resolves arg -> class macro -> config.
    # Symbol shorthands (:virtual/:local, :read_only/:auto/:ask/:approve) and
    # pre-built Sandbox/Permissions instances are both accepted. `loop:` injects
    # the engine that drives a prompt — the provider-neutral Loops::RubyLLM by
    # default, or a backend of your own.
    #
    # `decisions:` (default `nil`) are the per-call approval answers for an
    # `:approve` gate — a Hash of Permissions::approval_key → `true`/`false`. A
    # call found there runs or is refused; any other call pauses and #prompt
    # raises Nexo::ApprovalRequired. They only supply *answers* to an
    # already-`:approve` gate — they never widen capability. Workflow#run_agent
    # passes the approvals recorded on the run.
    #
    # `mcp_owner:` (0.15) is whose OAuth credentials this agent's `oauth:` MCP
    # servers use — a user record, or a stable String/Integer id.
    #
    # `answers:` (0.16) answers questions a tool asks the person — an MCP
    # server's, or a tool calling `ask` — keyed as Nexo::InputRequired reports
    # them. A value answers a one-field question, a Hash a form, `false` declines.
    # A question with no answer raises Nexo::InputRequired from #prompt.
    def initialize(cwd: Dir.pwd, model: nil, sandbox: nil, permissions: nil, decisions: nil,
      mcp_owner: nil, answers: nil, loop: Loops::RubyLLM.new)
      @mcp_owner = mcp_owner
      @answers = (answers || {}).to_h.transform_keys(&:to_s)
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
      @permissions = resolve_permissions(permissions || self.class.permissions, decisions: decisions)
      @instructions = self.class.instructions
      @loop = loop
    end

    # Builds a configured chat with the file and shell tools attached as
    # instances bound to this agent's sandbox and permissions, then layers on the
    # instructions of every declared skill.
    #
    # `base:` lets a Nexo::Session pass a persisted `acts_as_chat` record
    # (hydrated via ruby_llm's `#to_llm` delegation) so the very same wiring —
    # instructions, the sandbox tools, skills, MCP, fetch — is applied onto
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
      c = build_chat(base)
      c = apply_instructions(c)

      tools = file_tool_set
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
    #
    # `cancel:` (0.16) is a callable the loop asks around every tool call; when
    # it answers true the prompt stops with `RubyLLM::CancelledError`. It is
    # passed on only when given, so a loop backend of your own that does not
    # take it keeps working.
    def prompt(text, max_turns: 25, cancel: nil, &on_event)
      verify_environment!
      options = {agent: self, prompt: text, max_turns: max_turns}
      options[:cancel] = cancel if cancel
      @loop.run(**options, &on_event)
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

    # The `ruby_llm` MCP server declared as `name` with the `mcp` macro, built
    # with this agent's `mcp_owner`. For an `oauth:` server this is where a host
    # drives the authorization (0.15):
    #
    # ```ruby
    # agent  = Assistant.new(mcp_owner: current_user)
    # linear = agent.mcp_server(:linear)
    # redirect_to linear.authorization_url(redirect_uri: callback_url) unless linear.authorized?
    # # ...and in the callback action:
    # agent.mcp_server(:linear).authorize(params)
    # ```
    #
    # `#deauthorize` forgets the owner's credentials. Raises ConfigurationError
    # for a name that was never declared.
    def mcp_server(name)
      index = self.class.mcp.index { |cfg| cfg[:name].to_s == name.to_s } or
        raise ConfigurationError, "#{self.class} declares no mcp :#{name}"
      mcp_clients[index]
    end

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

    # The chat everything else is layered on: `base` (a session's record) or a
    # fresh one. An agent with an `llm` block gets it through that block's
    # `RubyLLM::Agent` class, which applies the declared model options; one
    # without is built exactly as before.
    #
    # VERIFIED (ruby_llm 2.2.3): `SomeAgent.chat(**options)` forwards the
    # options to `RubyLLM.chat` and returns the configured chat;
    # `SomeAgent.new(chat: existing, persist_instructions: false)` applies the
    # same declarations onto an existing chat or record and leaves its messages
    # and tools alone.
    def build_chat(base)
      options = self.class.llm
      return base || RubyLLM.chat(**chat_model_options) unless options
      return options.chat(**chat_model_options) unless base

      options.new(chat: base, persist_instructions: false)
      base
    end

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
    # agent's Permissions first. Attached after the sandbox tools and the
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

      require_mcp_authorization!
      self.class.mcp.zip(mcp_clients).group_by { |cfg, _| cfg[:defer] }.each do |defer, servers|
        gated = servers.flat_map { |cfg, client| gated_mcp_tools(cfg, client) }
        refuse_mcp_name_clash!(chat, gated)
        next if gated.empty?

        defer.nil? ? chat.with_tools(*gated) : chat.with_tools(*gated, defer: defer)
      end
      apply_mcp_resources(chat)
    end

    # One server's tools the model may call and the gate could allow, each
    # behind MCP::GatedTool and then the #wrap_mcp_tool hook.
    def gated_mcp_tools(cfg, client)
      client.tools.select { |tool| attachable_mcp_tool?(tool) }.map do |tool|
        wrap_mcp_tool(Nexo::MCP::GatedTool.new(tool: tool, permissions: @permissions, server: cfg[:name]))
      end
    end

    # Attaches `list_mcp_resources` and `read_mcp_resource` over the servers
    # declared with `resources: true`, each behind the MCP gate — and, like an
    # MCP tool, left out when `:read_only` could never allow it.
    def apply_mcp_resources(chat)
      servers = self.class.mcp.zip(mcp_clients).select { |cfg, _| cfg[:resources] }
        .to_h { |cfg, client| [cfg[:name].to_s, client] }
      return if servers.empty?

      tools = [Nexo::MCP::ListResources, Nexo::MCP::ReadResource].map { |tool| tool.new(servers: servers) }
        .reject { |tool| @permissions.never_allows_mcp?(tool.name) }
        .map { |tool| Nexo::MCP::GatedTool.new(tool: tool, permissions: @permissions) }
      chat.with_tools(*tools) unless tools.empty?
    end

    # Raises ConfigurationError when an MCP tool has the name of a tool already
    # on the chat. `ruby_llm`'s file tools have plain names (`read_file`,
    # `write_file`...), and so do the tools of a typical filesystem MCP server;
    # left alone the clash surfaces later as an ArgumentError from inside
    # `ruby_llm` that names neither the server nor the way out.
    def refuse_mcp_name_clash!(chat, gated)
      return unless chat.respond_to?(:tools)

      taken = chat.tools.keys.map(&:to_s)
      clash = gated.map { |tool| tool.name.to_s } & taken
      return if clash.empty?

      raise ConfigurationError,
        "#{self.class}: an MCP server offers #{clash.map { |name| "`#{name}`" }.join(", ")}, " \
        "which this agent already has as a tool of its own. If the agent should use the server's, " \
        "declare `file_tools :none`; otherwise leave those names out of `mcp_allow`."
    end

    # The agent's MCP servers, built once from the `mcp` declarations (with this
    # agent's `mcp_owner`) and reused until #close.
    def mcp_clients
      @mcp_clients ||= self.class.mcp.map { |cfg| Nexo::MCP.build(**cfg, owner: @mcp_owner) }
    end

    # Raises Nexo::AuthorizationRequired for the first server a person still has
    # to authorize. Checked before any tool is listed, so the host gets one clear
    # error to act on in place of a 401 from somewhere inside the first request.
    # Reads the credential store only — no network.
    def require_mcp_authorization!
      self.class.mcp.zip(mcp_clients).each do |cfg, client|
        next unless Nexo::MCP.user_authorized?(cfg)

        raise Nexo::AuthorizationRequired.new(cfg[:name]) unless client.authorized?
      end
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

    # The agent's file tools, per the `file_tools` declaration.
    #
    # A tool is attached only when the agent could actually use it: the gate must
    # not deny it statically (a :read_only agent can never be authorized for
    # :write), otherwise a guaranteed failure sits in the tool schema on every
    # turn and models do try it. #authorize! stays the actual boundary either way.
    def file_tool_set
      case self.class.file_tools
      when :core then core_file_tools
      when :none then []
      when :nexo
        raise ConfigurationError, "`file_tools :nexo` was removed in 0.16: Nexo's ReadFile, WriteFile and Glob " \
          "are gone. Use `:core` (the default: read_file, list_files, search_files, write_file, edit_file) or `:none`"
      else raise ConfigurationError, "unknown file_tools #{self.class.file_tools.inspect} (use :core or :none)"
      end
    end

    # `ruby_llm`'s file tools over one SandboxFileStore per chat, each behind
    # Nexo::GatedTool. They are built here and attached with `with_tools` — NOT
    # with `chat.with_file_store`, which would attach them with no place for the
    # gate. The gate is told the path the call acts on.
    #
    # `ruby_llm` treats every path as relative to the store, so `/workspace/a.md`
    # would be looked up as `workspace/a.md`. The sandbox tells the model an
    # absolute working directory, so an absolute path inside it is made relative
    # before the gate and the tool see it (#sandbox_relative).
    #
    # VERIFIED (ruby_llm 2.2.3): `FileStore::Tools.classes(names)` returns the
    # tool classes for `:read` (list, read, search), `:write` and `:edit`, each
    # built with `store:` (a callable). These are internal to `ruby_llm`; the
    # real-loop tests are what catches a change.
    def core_file_tools
      store = SandboxFileStore.new(@sandbox)
      groups = {read: :read}
      groups = groups.merge(write: :write, edit: :write) unless @permissions.never_allows?(:write)
      groups.flat_map do |group, capability|
        ::RubyLLM::FileStore::Tools.classes([group]).map do |tool|
          Nexo::GatedTool.new(tool: tool.new(store: -> { store }), permissions: @permissions,
            capability: capability, detail: ->(arguments) { arguments[:path] },
            prepare: ->(arguments) { sandbox_relative(arguments) })
        end
      end
    end

    # `arguments` with an absolute `:path` inside the sandbox's working directory
    # made relative to it. The directory itself becomes no path at all, which the
    # listing and search tools read as "everything". Any other path is left alone.
    def sandbox_relative(arguments)
      path = arguments[:path]
      root = @sandbox.cwd.to_s.chomp("/") if @sandbox.respond_to?(:cwd)
      return arguments unless path.is_a?(String) && root && !root.empty?
      return arguments.except(:path) if path.chomp("/") == root
      return arguments unless path.start_with?("#{root}/")

      arguments.merge(path: path.delete_prefix("#{root}/"))
    end

    # Attaches the tools declared with the `tools` macro. One declared with a
    # `capability:` is wrapped in Nexo::GatedTool, and skipped altogether when the
    # gate could never authorize it.
    def apply_host_tools(chat)
      self.class.tools.group_by { |entry| entry[:defer] }.each do |defer, entries|
        built = entries.flat_map { |entry| gated_host_tools(entry) }
        next if built.empty?

        defer.nil? ? chat.with_tools(*built) : chat.with_tools(*built, defer: defer)
      end
    end

    # The tools of one `tools` declaration, gated when it names a capability.
    def gated_host_tools(entry)
      capability = entry[:capability]
      return [] if capability && @permissions.never_allows?(capability)

      build_host_tools(entry[:tool]).map do |tool|
        capability ? Nexo::GatedTool.new(tool: tool, permissions: @permissions, capability: capability) : tool
      end
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
    # Under `Nexo.config.strict_tools` (the default) such a call is skipped —
    # `ruby_llm` then tells the model the call did not run; with it off the call
    # runs. Either way Nexo warns once per tool.
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
        name = (tool_call.respond_to?(:qualified_name) ? tool_call.qualified_name : tool_call.name).to_s
        if chat.instance_variable_get(:@nexo_known_tools).include?(name) || !chat.tools.key?(name.to_sym)
          # Known to Nexo — or not on the chat at all, in which case nothing runs
          # and `ruby_llm` answers the model with its own "no tool named" error.
          run.call
        else
          refused = Nexo.config.strict_tools
          Nexo.warn_undeclared_tool(name, self.class, refused: refused)
          run.call unless refused
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

    def resolve_permissions(value, decisions: nil)
      # A user-supplied Permissions sets its own mcp_allow: — leave it untouched.
      # Thread the run's approval answers through a non-mutating copy (Spec 16)
      # so a shared, class-level :approve instance is never clobbered.
      return (decisions ? value.with_decisions(decisions) : value) if value.is_a?(Permissions)

      # Thread the class-level mcp_allow into each symbol branch (Spec 6) so the
      # MCP capability axis is populated alongside the sandbox axis.
      allow = self.class.mcp_allow
      case value
      when :read_only then Permissions.new(mode: :read_only, mcp_allow: allow)
      when :auto then Permissions.new(mode: :auto, allow: %i[read glob write shell fetch search], mcp_allow: allow)
      when :ask then Permissions.new(mode: :ask, mcp_allow: allow) # pass a Permissions with on_ask for a real gate
      when :approve then Permissions.new(mode: :approve, mcp_allow: allow, decisions: decisions)
      else raise ConfigurationError, "unknown permissions: #{value.inspect}"
      end
    end
  end
end
