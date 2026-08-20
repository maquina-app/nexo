# frozen_string_literal: true

module Nexo
  # Composes the +ruby_llm-skills+ gem so a developer can drop a SKILL.md package
  # into +app/skills/<name>/+ and attach it to an agent with a single +skills+
  # class macro — no loader wiring.
  #
  # +ruby_llm-skills+ is a SOFT (optional) runtime dependency: it is required
  # lazily by load! the first time a skill is used. With the gem absent,
  # +require "nexo"+ still loads cleanly; only touching a skill raises
  # MissingDependencyError with install guidance.
  #
  # A loaded skill contributes its **instructions** (the SKILL.md body) to a chat.
  # It ships no independent tools, so attaching a skill never widens the agent's
  # effective capabilities.
  #
  # Its +scripts/+, +assets/+ and +references/+ files are NOT reachable on their
  # own: a skill lives under +skills_path+, every sandbox confines file access to
  # its own working directory, and nothing bridges the two. To let an agent read or
  # run a skill's bundled files, copy them into the sandbox first — through the
  # sandbox's own +#write+, so it works on every tier. They are then reached through
  # Nexo's permission-gated tools like any other workspace file. See the
  # spec's "Verified APIs" / safety resolution for why the gem's progressive
  # disclosure +SkillTool+ (which does ungated +File.read+) is deliberately not
  # attached.
  module Skills
    class << self
      # Lazily loads the +ruby_llm-skills+ gem. Idempotent (a second call is a
      # cheap no-op once the gem is loaded). Raises MissingDependencyError —
      # naming the gem and the exact remedy — when the gem is not installed.
      def load!
        require "ruby_llm/skills"
      rescue LoadError
        raise MissingDependencyError,
          'Skills require the `ruby_llm-skills` gem. Add `gem "ruby_llm-skills"` to your Gemfile.'
      end

      # Resolves a skill +name+ (symbol or string) to a loaded skill object read
      # from the filesystem under Nexo.config.skills_path. The filesystem is the
      # only skill source in v1 — zip/DB/remote loading is deferred entirely to
      # +ruby_llm-skills+.
      #
      # Calls load! first (so an absent gem surfaces MissingDependencyError),
      # then resolves +<skills_path>/<name>/SKILL.md+. A missing file raises
      # Error whose message names the resolved path.
      #
      # @return [RubyLLM::Skills::Skill] the loaded skill (exposes +#content+,
      #   +#name+, +#description+).
      def find(name)
        load!

        dir = File.join(Nexo.config.skills_path.to_s, name.to_s)
        skill_md = File.join(dir, "SKILL.md")
        raise Error, "skill not found: #{skill_md}" unless File.exist?(skill_md)

        RubyLLM::Skills.load(dir)
      end
    end
  end
end
