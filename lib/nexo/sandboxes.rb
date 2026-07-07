# frozen_string_literal: true

module Nexo
  # Namespace for the concrete sandbox tiers plus the single resolver shared by
  # {Agent} and {Workflow} so the two can't drift (Spec 15). Reproduces the
  # Agent's prior resolution *exactly*; the host +cwd:+ applies only to +:local+
  # (a {Sandboxes::Container} keeps its own +/workspace+ default — the host dir
  # enters a container only through a +binds:+ entry).
  module Sandboxes
    module_function

    # Resolves a sandbox declaration (symbol / Hash / pre-built instance) into a
    # concrete {Sandbox}. +cwd:+ is the host working directory used only by
    # +:local+; container tiers ignore it. Raises {ConfigurationError} for an
    # unknown value, and +image:+ stays required for containers (the
    # {Sandboxes::Container} constructor raises when it is absent).
    def resolve(value, cwd: Dir.pwd)
      return value if value.is_a?(Nexo::Sandbox)

      case value
      when :virtual then Virtual.new
      when :local then Local.new(cwd: cwd)
      when :docker, :apple then Container.new(runtime: value) # image: required -> raises if absent
      when Hash then resolve_hash(value, cwd)
      else raise Nexo::ConfigurationError, "unknown sandbox: #{value.inspect}"
      end
    end

    # Resolves the +{ type:, **opts }+ Hash form. +:docker+/+:apple+ pass every
    # other key straight through to {Sandboxes::Container} (so an explicit Hash
    # +cwd:+ or the +/workspace+ default wins — never the host +cwd+); +:local+
    # honors an explicit Hash +cwd:+, otherwise falls back to the host +cwd+.
    def resolve_hash(opts, cwd)
      type = opts.fetch(:type)
      rest = opts.except(:type)
      case type
      when :docker, :apple then Container.new(runtime: type, **rest)
      when :local then Local.new(cwd: rest.fetch(:cwd, cwd))
      else raise Nexo::ConfigurationError, "unknown sandbox type: #{type.inspect}"
      end
    end
  end
end
