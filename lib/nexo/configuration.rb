# frozen_string_literal: true

module Nexo
  # Holds the harness-wide defaults. Accessed through {Nexo.config} and
  # mutated through {Nexo.configure}. Every default is safe-by-default and
  # provider-neutral — there is intentionally no hardcoded model.
  class Configuration
    # The default ruby_llm model id. +nil+ means none chosen — provider-neutral.
    attr_accessor :default_model

    # The default sandbox: +:virtual+ (in-memory, zero host access).
    attr_accessor :default_sandbox

    # The default permission mode: +:read_only+.
    attr_accessor :default_permissions

    # Where SKILL.md packages live. Rails-aware: +app/skills+ under the app root.
    attr_accessor :skills_path

    def initialize
      @default_model = nil # provider-neutral: NO hardcoded default
      @default_sandbox = :virtual # safe default
      @default_permissions = :read_only # safe default
      @skills_path = default_skills_path
    end

    private

    def default_skills_path
      if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.join("app/skills").to_s
      else
        "skills"
      end
    end
  end
end
