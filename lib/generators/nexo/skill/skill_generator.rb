# frozen_string_literal: true

require "rails/generators"
require "rails/generators/named_base"

module Nexo
  module Generators
    # Scaffolds an Agent Skills package in a host Rails app:
    #
    #   rails g nexo:skill triage
    #
    # creates +app/skills/triage/SKILL.md+ (valid frontmatter + placeholder
    # process steps, per agentskills.io/specification) and a kept
    # +app/skills/triage/references/+ directory for supporting docs the skill can
    # cite. Reference it from an agent with the +skills :triage+ macro.
    #
    # Rails-coupled, like Nexo's other generators: it requires +rails/generators+
    # at load time and is never autoloaded by the plain-Ruby core, so
    # +require "nexo"+ with no Rails present neither defines nor fails on it.
    class SkillGenerator < Rails::Generators::NamedBase
      source_root File.expand_path("templates", __dir__)

      def create_skill_package
        empty_directory File.join(skill_root, "references")
        # An empty references/ would not survive git; .keep keeps it tracked.
        create_file File.join(skill_root, "references", ".keep")
        template "SKILL.md.tt", File.join(skill_root, "SKILL.md")
      end

      private

      def skill_root
        File.join("app", "skills", file_name)
      end

      # A human-readable heading from the skill name ("issue_triage" / "issue-triage"
      # -> "Issue Triage").
      def skill_title
        file_name.split(/[_-]/).reject(&:empty?).map(&:capitalize).join(" ")
      end
    end
  end
end
