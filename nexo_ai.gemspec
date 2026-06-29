# frozen_string_literal: true

require_relative "lib/nexo/version"

Gem::Specification.new do |spec|
  spec.name = "nexo_ai"
  spec.version = Nexo::VERSION
  spec.authors = ["Mario Alberto Chávez"]
  spec.email = ["mario.chavez@gmail.com"]

  spec.summary = "Agent = Model + Harness. Nexo is the connective tissue linking RubyLLM to tools, sandboxes, skills, and runs."
  spec.description = "An opinionated, drop-in agent harness for RubyLLM. Nexo composes the RubyLLM ecosystem into one coherent front door, adding a Sandbox+Permissions seam and a WorkflowRun lifecycle primitive."
  spec.homepage = "https://maquina.app"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/maquina-app/nexo"
  spec.metadata["changelog_uri"] = "https://github.com/maquina-app/nexo/blob/main/CHANGELOG.md"

  # Uncomment the line below to require MFA for gem pushes.
  # This helps protect your gem from supply chain attacks by ensuring
  # no one can publish a new version without multi-factor authentication.
  # See: https://guides.rubygems.org/mfa-requirement-opt-in/
  # spec.metadata["rubygems_mfa_required"] = "true"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore test/ .github/ .rubocop.yml .claude/])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime dependencies. Provider neutrality is a hard rule: the only vendor-facing
  # dependency is ruby_llm, which reaches every LLM provider through one interface.
  # Soft deps (ruby_llm-skills / ruby_llm-mcp / ruby_llm-agent_sdk) are intentionally
  # NOT declared here — they are lazily required in their own specs.
  spec.add_dependency "ruby_llm", ">= 1.16"
  spec.add_dependency "zeitwerk", "~> 2.6"

  # Dev dependencies. ruby_llm-test stubs models so the suite runs offline (first
  # exercised in Spec 1). minitest and rake remain declared in the Gemfile.
  spec.add_development_dependency "ruby_llm-test"
  spec.add_development_dependency "standard"

  # ruby_llm-skills is a SOFT/optional runtime dependency (Spec 3): Nexo::Skills.load!
  # requires it lazily behind a rescue that raises Nexo::MissingDependencyError, so it
  # is intentionally NOT a runtime add_dependency — `require "nexo"` with the gem absent
  # must not raise. It is a DEV dependency so the offline suite exercises real skill
  # loading against an on-disk fixture.
  spec.add_development_dependency "ruby_llm-skills"

  # Rails path (Spec 2): the engine, generator, WorkflowRun model, and the
  # test/dummy app. These are never runtime deps — the core runs in plain Ruby
  # with no Rails loaded, and the offline test suite never touches ActiveRecord.
  spec.add_development_dependency "rails", ">= 8.0"
  spec.add_development_dependency "sqlite3", ">= 2.0"

  # For more information and examples about making a new gem, check out our
  # guide at: https://guides.rubygems.org/make-your-own-gem/
end
