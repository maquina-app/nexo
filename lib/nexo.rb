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
# The published gem is +nexo_ai+; the Ruby namespace is always +Nexo+.
module Nexo
  # Base class for every error Nexo raises. Library misuse (programmer/config
  # errors) raises one of these; tool runtime failures do not — they return
  # a Hash with an +:error+ key so the model can recover.
  class Error < StandardError; end

  # Raised when an optional (soft) dependency is required but not installed.
  # The message names the missing gem and how to install it. Not raised in
  # Spec 0 — the soft-dep guards arrive with their own specs.
  class MissingDependencyError < Error; end

  # Raised on invalid or incomplete configuration (e.g. an agent built with
  # no model and no configured default).
  class ConfigurationError < Error; end

  # Control-flow signal raised by the +:approve+ permission gate (Spec 16) when a
  # capability needs a human decision and none has been threaded in yet. Unlike
  # Permissions::Denied ("no, adapt" — tools rescue it into +{error:}+),
  # +ApprovalRequired+ means "pause and ask a human": tools must **not** rescue
  # it, so it propagates out of the +ruby_llm+ tool loop and out of
  # Agent#prompt, where Workflow#run_agent catches it and turns it into a
  # durable Workflow#suspend!. It subclasses +StandardError+ directly (not
  # Error), mirroring Permissions::Denied's base — it is a signal, not a
  # library-misuse error. Carries the pending call's +capability+, +detail+ (the
  # tool/path), and +args+ so a host can render the approval prompt from
  # +run.state["__approval__"]+.
  class ApprovalRequired < StandardError
    # The pending call's capability (e.g. +:write+), its +detail+ (the tool/path),
    # and the tool +args+ — enough for a host to render the approval prompt.
    attr_reader :capability, :detail, :args

    # Builds the signal for +capability+ acting on +detail+ with +args+; the
    # message reads "approval required for <capability> (<detail>)".
    def initialize(capability, detail = nil, args = nil)
      @capability = capability
      @detail = detail
      @args = args
      super("approval required for #{capability} (#{detail})")
    end
  end

  class << self
    # Yields the singleton Configuration for in-place setup and returns it.
    #
    #   Nexo.configure { |config| config.default_model = ENV["NEXO_MODEL"] }
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

    # Returns a fresh run id as a time-ordered UUID v7 string (Ruby 3.3+).
    # Both run stores and the WorkflowRun model obtain ids only through this
    # helper, keeping id shape identical across backends.
    def generate_run_id
      SecureRandom.uuid_v7
    end

    # Bounded, fiber-based fan-out (Spec 5). Yields a collector; every block
    # added via +c.add { ... }+ runs concurrently inside one +async+ reactor,
    # capped at +max_in_flight+ in flight, with results returned in submission
    # order and the first task error re-raised. Requires the optional +async+
    # gem — raises MissingDependencyError if it is not installed.
    #
    #   results = Nexo.concurrent(max_in_flight: 8) do |c|
    #     docs.each { |d| c.add { SummarizeDocument.run(text: d.body).result } }
    #   end
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
# Loop-backend filenames carry acronyms Zeitwerk can't infer on its own:
# lib/nexo/loops/ruby_llm.rb -> Nexo::Loops::RubyLLM and
# lib/nexo/loops/agent_sdk.rb -> Nexo::Loops::AgentSDK (Spec 4).
loader.inflector.inflect(
  "ruby_llm" => "RubyLLM",
  "agent_sdk" => "AgentSDK",
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
loader.setup

# Rails-optional: only pull in the engine when Rails is present. Loading Nexo
# in plain Ruby (no Rails) must not raise.
require_relative "nexo/engine" if defined?(::Rails::Engine)
