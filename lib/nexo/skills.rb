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

      # Copies a skill's bundled files INTO a sandbox, so an agent can read or run
      # them through its permission-gated tools.
      #
      # A skill lives under +skills_path+, outside every sandbox, and each sandbox
      # confines file access to its own working directory — so +scripts/+, +assets/+
      # and +references/+ are unreachable until they are staged. This is that step.
      #
      # It goes through the sandbox's own +#write+, which is the ONLY route that works
      # on every tier: +Local+ writes to the filesystem, +Container+ streams over
      # +docker exec+ / +container exec+, and +Remote+ hands off to the injected
      # client. Nothing here knows or cares which one it is.
      #
      #   Nexo::Skills.materialize(:dashboard_designer, into: agent.sandbox)
      #   # => { scripts: ["scripts/render_dashboard.rb"],
      #   #      assets:  ["assets/dashboard-template.html"] }
      #
      # Returns the SANDBOX-RELATIVE path of every file written, grouped by kind, so a
      # caller can build a command without knowing where the sandbox lives. Build
      # commands from these relative paths — a host-absolute path is meaningless
      # inside a container and on another machine.
      #
      # Kinds a skill ships nothing for are omitted. +kinds:+ narrows the copy;
      # +overwrite: false+ skips files already present, which is what you want against
      # an image that already bakes the skill in.
      #
      # SECURITY: staged files land in WRITABLE space. An agent holding +:write+ and
      # +:shell+ can rewrite a script before executing it — where the same file, left
      # outside the sandbox, could not be touched at all. Re-materializing on every run
      # bounds tampering to a single turn; if that is not enough, keep the resource out
      # of the sandbox and feed the agent its contents another way.
      def materialize(name, into:, kinds: %i[scripts assets references], overwrite: true)
        skill = name.respond_to?(:scripts) ? name : find(name)

        Array(kinds).each_with_object({}) do |kind, staged|
          files = resources(skill, kind)
          next if files.empty?

          staged[kind] = files.map { |host_path| copy_in(host_path, kind, into, overwrite) }
        end
      end

      private

      # A skill's files of one kind, as host paths. Virtual (database-backed) skills
      # have no filesystem resources and answer with an empty list.
      def resources(skill, kind)
        return [] unless %i[scripts assets references].include?(kind.to_sym)
        return [] unless skill.respond_to?(kind)

        Array(skill.public_send(kind))
      end

      # Writes one host file into the sandbox under +<kind>/<basename>+, preserving the
      # layout a skill's own prose refers to ("run scripts/render.rb").
      def copy_in(host_path, kind, sandbox, overwrite)
        relative = File.join(kind.to_s, File.basename(host_path))
        return relative if !overwrite && present?(sandbox, relative)

        sandbox.write(relative, File.binread(host_path))
        relative
      end

      def present?(sandbox, relative)
        sandbox.read(relative)
        true
      rescue
        false
      end
    end
  end
end
