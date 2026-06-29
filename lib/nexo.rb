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

  class << self
    # Yields the singleton {Configuration} for in-place setup and returns it.
    #
    #   Nexo.configure { |config| config.default_model = ENV["NEXO_MODEL"] }
    def configure
      yield(config)
      config
    end

    # Returns the memoized singleton {Configuration}.
    def config
      @config ||= Configuration.new
    end

    # Replaces the singleton with a fresh {Configuration}. Test helper for
    # isolating the global between examples.
    def reset_config!
      @config = Configuration.new
    end

    # Returns a fresh run id as a UUID string. Uses UUID v7 (time-ordered)
    # when available (Ruby 3.3+) and falls back to UUID v4 on Ruby 3.2 so the
    # gem stays 3.2-compatible. Both run stores and the WorkflowRun model obtain
    # ids only through this helper, keeping id shape identical across backends.
    def generate_run_id
      if SecureRandom.respond_to?(:uuid_v7)
        SecureRandom.uuid_v7
      else
        SecureRandom.uuid
      end
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
  "agent_sdk" => "AgentSDK"
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
loader.setup

# Rails-optional: only pull in the engine when Rails is present. Loading Nexo
# in plain Ruby (no Rails) must not raise.
require_relative "nexo/engine" if defined?(::Rails::Engine)
