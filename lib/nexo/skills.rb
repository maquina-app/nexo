# frozen_string_literal: true

module Nexo
  # Skills: drop a SKILL.md package into `app/skills/<name>/` and attach it to an
  # agent with a single `skills` class macro — no loader wiring, and no extra gem.
  #
  # A loaded skill contributes its **instructions** (the SKILL.md body) to a chat.
  # It ships no independent tools, so attaching a skill never widens the agent's
  # effective capabilities.
  #
  # Its `scripts/`, `assets/` and `references/` files are NOT reachable on their
  # own: a skill lives under `skills_path`, every sandbox confines file access to
  # its own working directory, and nothing bridges the two. To let an agent read or
  # run a skill's bundled files, copy them into the sandbox first — through the
  # sandbox's own `#write`, so it works on every tier. They are then reached through
  # Nexo's permission-gated tools like any other workspace file.
  #
  # `ruby_llm` has its own skills (`Chat#with_skills`, which adds a `load_skill`
  # tool). Nexo does not attach it: skill text goes in as instructions, and a
  # skill's files are reached only through the gated sandbox tools.
  module Skills
    class << self
      # Resolves a skill `name` (symbol or string) to a Skills::Skill read from
      # `<skills_path>/<name>/SKILL.md` under Nexo.config.skills_path. The
      # filesystem is the only skill source.
      #
      # A missing file raises Error whose message names the resolved path.
      def find(name)
        Skill.new(File.join(Nexo.config.skills_path.to_s, name.to_s))
      end

      # Copies a skill's bundled files INTO a sandbox, so an agent can read or run
      # them through its permission-gated tools.
      #
      # A skill lives under `skills_path`, outside every sandbox, and each sandbox
      # confines file access to its own working directory — so `scripts/`, `assets/`
      # and `references/` are unreachable until they are staged. This is that step.
      #
      # It goes through the sandbox's own `#write`, which is the ONLY route that works
      # on every tier: `Local` writes to the filesystem, `Container` streams over
      # `docker exec` / `container exec`, and `Remote` hands off to the injected
      # client. Nothing here knows or cares which one it is.
      #
      # ```ruby
      # Nexo::Skills.materialize(:dashboard_designer, into: agent.sandbox)
      # # => { scripts: ["scripts/render_dashboard.rb"],
      # #      assets:  ["assets/dashboard-template.html"] }
      # ```
      #
      # Returns the SANDBOX-RELATIVE path of every file written, grouped by kind, so a
      # caller can build a command without knowing where the sandbox lives. Build
      # commands from these relative paths — a host-absolute path is meaningless
      # inside a container and on another machine.
      #
      # Kinds a skill ships nothing for are omitted. `kinds:` narrows the copy;
      # `overwrite: false` skips files already present, which is what you want against
      # an image that already bakes the skill in.
      #
      # SECURITY: staged files land in WRITABLE space. An agent holding `:write` and
      # `:shell` can rewrite a script before executing it — where the same file, left
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

      # A skill's files of one kind, as host paths. An object that does not answer
      # the kind (a skill double with no bundled files) yields an empty list.
      def resources(skill, kind)
        return [] unless %i[scripts assets references].include?(kind.to_sym)
        return [] unless skill.respond_to?(kind)

        Array(skill.public_send(kind))
      end

      # Writes one host file into the sandbox under `<kind>/<basename>`, preserving the
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
