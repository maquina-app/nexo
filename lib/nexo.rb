# frozen_string_literal: true

require "securerandom"
require "zeitwerk"

# ruby_llm is Nexo's only hard runtime LLM dependency (provider neutrality is a
# hard rule — every provider is reached through this one interface). It is
# required up front so the sandbox-backed tools under lib/nexo/tools/ can
# subclass RubyLLM::Tool when Zeitwerk autoloads them.
require "ruby_llm"

require_relative "nexo/version"

# Nexo composes the RubyLLM ecosystem into one front door, adding a
# Sandbox + Permissions seam and a WorkflowRun lifecycle primitive.
#
# The published gem is `nexo_ai`; the Ruby namespace is always `Nexo`.
module Nexo
  # Base class for every error Nexo raises. Library misuse (programmer/config
  # errors) raises one of these; tool runtime failures do not — they return
  # a Hash with an `:error` key so the model can recover.
  class Error < StandardError; end

  # Raised when an optional (soft) dependency is required but not installed.
  # The message names the missing gem and how to install it. Not raised in
  # Spec 0 — the soft-dep guards arrive with their own specs.
  class MissingDependencyError < Error; end

  # Raised on invalid or incomplete configuration (e.g. an agent built with
  # no model and no configured default).
  class ConfigurationError < Error; end

  # Raised when an agent's declared `requires` are not met by the sandbox it is
  # about to run in — no interpreter on `PATH`, or no UTF-8 locale. A
  # configuration error in spirit, but named separately because the fix is in the
  # image or the sandbox wiring rather than in the Ruby.
  class EnvironmentError < ConfigurationError; end

  # Raised when an agent is about to use an MCP server that a person has not
  # authorized yet (an `oauth:` server on the authorization-code grant). Carries
  # the `server` so a host can send the user to
  # `agent.mcp_server(server).authorization_url(redirect_uri:)`.
  class AuthorizationRequired < Error
    # The `mcp` macro name of the server that needs authorizing.
    attr_reader :server

    # The scopes the server asked for when it refused a call for want of one
    # (0.16), as Strings. Empty for a server that was never authorized.
    attr_reader :scopes

    # Builds the error for the MCP server declared as `server`. With `scopes:`
    # it reports a server that refused a call because the stored grant lacks
    # them: the fix is the same — send the user through the authorization URL
    # again, which asks for the wider grant.
    def initialize(server, scopes: [])
      @server = server.to_sym
      @scopes = Array(scopes).map(&:to_s)
      reason = @scopes.empty? ? "is not authorized" : "needs more access (#{@scopes.join(", ")})"
      super("MCP server :#{server} #{reason} — send the user to " \
        "agent.mcp_server(:#{server}).authorization_url(redirect_uri:) first")
    end
  end

  # Raised when a tool asked the person something and nobody has answered yet
  # (0.16) — an MCP server's question (elicitation), or a `RubyLLM::Tool` that
  # calls `ask`. Like ApprovalRequired it is a signal, not a failure:
  # Workflow#run_agent turns it into a durable suspend, and a direct caller can
  # rescue it, put the #questions to the person, and prompt again with
  # `Agent.new(answers:)`.
  class InputRequired < StandardError
    # One question, reduced to plain data so it survives a run store: the `key`
    # an answer is filed under, the `tool` that asked, the `message` to show,
    # the `fields` to collect (each a Hash of name, type, title, required,
    # choices), and a `url` when the person is asked to visit a page instead.
    Question = Struct.new(:key, :tool, :message, :fields, :url) do
      # The question as a String-keyed Hash, for a run's state.
      def to_h = {"key" => key, "tool" => tool, "message" => message, "fields" => fields, "url" => url}.compact
    end

    # The unanswered questions, each a Question.
    attr_reader :questions

    # The conversation up to the question, as plain data (0.17). Hand it back
    # with `prompt(text, continue: error.transcript)` and the paused call carries
    # on, in place of the prompt being asked again.
    attr_accessor :transcript

    # Builds the signal for `questions` (Question structs).
    def initialize(questions)
      @questions = questions
      super("input required: #{questions.map(&:message).compact.join(" / ")}")
    end

    # The key an answer to `question` (a `RubyLLM::Question`) is filed under:
    # the tool that asked, then the question's own key. The same call asking
    # the same thing on a later run gets the same key.
    def self.key_for(question)
      "#{question.tool_call&.name}:#{question.key}"
    end

    # Reduces a `RubyLLM::Question` to a Question struct.
    def self.reduce(question)
      fields = Array(question.fields).map do |field|
        {"name" => field.name.to_s, "type" => field.type, "title" => field.title,
         "required" => field.required, "choices" => field.choices}.compact
      end
      Question.new(key_for(question), question.tool_call&.name.to_s, question.message,
        fields, (question.url if question.url?))
    end
  end

  # Raised from Agent#prompt when a call under an `:approve` gate needs a
  # person's decision and none is recorded. Unlike Permissions::Denied ("no,
  # adapt"), it means "pause and ask a human": Workflow#run_agent turns it into
  # a durable Workflow#suspend!, and a direct caller can rescue it, ask, and
  # prompt again with `Agent.new(decisions:)`.
  #
  # Since 0.16 the pause itself is `ruby_llm`'s (see Approvable): the model's
  # tool calls are held before any of them runs, and the loop raises this for
  # the first undecided one, with every undecided call of that response in
  # #pending. The gate inside a tool still raises it for a call that reached the
  # tool undecided some other way. It subclasses `StandardError` directly (not
  # Error), like Permissions::Denied — it is a signal, not a library-misuse
  # error.
  class ApprovalRequired < StandardError
    # The pending call's capability (e.g. `:write`), its `detail` (the tool/path),
    # and the tool `args` — enough for a host to render the approval prompt.
    attr_reader :capability, :detail, :args

    # Every call waiting for a decision, this one first: an Array of
    # String-keyed Hashes with `"capability"`, `"tool"` (the detail), `"args"`
    # and the `"key"` to record a decision under.
    attr_reader :pending

    # The conversation up to the held call, as plain data (0.17). Hand it back
    # with `Agent.new(decisions:).prompt(text, continue: error.transcript)` and
    # the held call runs (or is refused) without the model being asked again.
    attr_accessor :transcript

    # The key this call is decided under — see Permissions::approval_key.
    def key = Permissions.approval_key(capability, detail, args)

    # This call as a String-keyed Hash, the shape of one #pending entry.
    def to_h = {"capability" => capability.to_s, "tool" => detail.to_s, "args" => args, "key" => key}

    # Builds the signal for `capability` acting on `detail` with `args`; the
    # message reads "approval required for <capability> (<detail>)". `pending:`
    # lists every waiting call when there are several (see #pending).
    def initialize(capability, detail = nil, args = nil, pending: nil)
      @capability = capability
      @detail = detail
      @args = args
      @pending = pending || [to_h]
      super("approval required for #{capability} (#{detail})")
    end
  end

  @undeclared_tools = Set.new
  @undeclared_tools_lock = Mutex.new

  class << self
    # Yields the singleton Configuration for in-place setup and returns it.
    #
    # ```ruby
    # Nexo.configure { |config| config.default_model = ENV["NEXO_MODEL"] }
    # ```
    def configure
      yield(config)
      config
    end

    # Returns the memoized singleton Configuration.
    def config
      @config ||= Configuration.new
    end

    # Replaces the singleton with a fresh Configuration. Test helper for
    # isolating the global between examples.
    def reset_config!
      @config = Configuration.new
    end

    # Warns, once per tool name, that the model called a tool Nexo did not attach
    # (see Configuration#strict_tools), and says whether the call was refused.
    # Called from the tool backstop, possibly on several tool threads at once,
    # hence the lock.
    def warn_undeclared_tool(name, agent_class, refused: false)
      return unless first_warning?(:"tool:#{name}")

      outcome = refused ? "The call was refused" : "The call ran with no permission gate"
      notice "[nexo] #{agent_class}: the model called `#{name}`, a tool added to the chat outside " \
        "the `tools` macro. #{outcome} (Nexo.config.strict_tools is #{refused}). Declare it " \
        "with `tools` on the agent, optionally with `capability:`."
    end

    # Writes one operational notice to standard error. Not `Kernel#warn`: that
    # prints nothing when Ruby runs with `-W0`, and a refused tool call or a
    # removal notice is not a language warning to be silenced with those.
    def notice(message)
      $stderr.write("#{message}\n")
    end

    # Whether `key` is being warned about for the first time in this process.
    def first_warning?(key)
      @undeclared_tools_lock.synchronize do
        return false if @undeclared_tools.include?(key)

        @undeclared_tools << key
        true
      end
    end

    # Returns a fresh run id as a time-ordered UUID v7 string (Ruby 3.3+).
    # Both run stores and the WorkflowRun model obtain ids only through this
    # helper, keeping id shape identical across backends.
    def generate_run_id
      SecureRandom.uuid_v7
    end

    # Bounded, fiber-based fan-out (Spec 5). Yields a collector; every block
    # added via `c.add { ... }` runs concurrently inside one `async` reactor,
    # capped at `max_in_flight` in flight, with results returned in submission
    # order and the first task error re-raised. Requires the optional `async`
    # gem — raises MissingDependencyError if it is not installed.
    #
    # ```ruby
    # results = Nexo.concurrent(max_in_flight: 8) do |c|
    #   docs.each { |d| c.add { SummarizeDocument.run(text: d.body).result } }
    # end
    # ```
    def concurrent(max_in_flight: config.max_in_flight, &setup)
      c = Concurrent.new(max_in_flight: max_in_flight)
      setup.call(c)
      c.run
    end
  end
end

# Zeitwerk autoloads everything under lib/nexo/** into the Nexo namespace.
# for_gem (called from lib/nexo.rb) roots the loader at lib/ and treats
# lib/nexo.rb as the gem's main file.
loader = Zeitwerk::Loader.for_gem
# Filenames carrying acronyms Zeitwerk can't infer on its own:
# lib/nexo/loops/ruby_llm.rb -> Nexo::Loops::RubyLLM and lib/nexo/mcp.rb -> Nexo::MCP.
loader.inflector.inflect(
  "ruby_llm" => "RubyLLM",
  "mcp" => "MCP"
)
# The require-shim is not a managed constant — Zeitwerk must not infer a constant
# from its filename (the namespace is always Nexo), and ignoring it suppresses
# for_gem's extra-file warning.
loader.ignore("#{__dir__}/nexo_ai.rb")
# Rails generators are loaded by Rails, never autoloaded by us.
loader.ignore("#{__dir__}/generators")
# Rake tasks live under lib/tasks and are loaded by the Rails engine (or a host
# app's Rakefile), never autoloaded as constants.
loader.ignore("#{__dir__}/tasks")
# The WorkflowRun ActiveRecord model is Rails-only: its body subclasses
# ::ActiveRecord::Base, which the plain-Ruby path must never touch. Ignoring it
# here means no autoload is registered, so defined?(Nexo::WorkflowRun) stays
# false without Rails and RunStore.default correctly selects the Memory backend.
# The engine requires it once ActiveRecord is loaded.
loader.ignore("#{__dir__}/nexo/workflow_run.rb")
# The WorkflowJob (Rails-only, subclasses ::ActiveJob::Base) and TurboBroadcaster
# (guarded on ::ActiveSupport::Notifications) mirror workflow_run.rb: guarded body,
# Zeitwerk-ignored (no autoload registered, so they stay undefined without Rails),
# required by engine initializers once ActiveJob / ActiveSupport are present.
loader.ignore("#{__dir__}/nexo/workflow_job.rb")
loader.ignore("#{__dir__}/nexo/turbo_broadcaster.rb")
# The Engine (Rails-only, subclasses ::Rails::Engine) is the same guarded-body
# pattern: Zeitwerk must NOT register an autoload it can't satisfy without Rails
# (which would turn a plain-Ruby Nexo::Engine reference — or an eager_load — into
# a Zeitwerk::NameError). It is required explicitly below when Rails is present.
loader.ignore("#{__dir__}/nexo/engine.rb")
loader.setup

# Rails-optional: only pull in the engine when Rails is present. Loading Nexo
# in plain Ruby (no Rails) must not raise.
require_relative "nexo/engine" if defined?(::Rails::Engine)
