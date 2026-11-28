# frozen_string_literal: true

require "yaml"

module Nexo
  module Skills
    # One skill: a folder holding a `SKILL.md` (YAML front matter, then the
    # instructions) and, optionally, `scripts/`, `assets/` and `references/`.
    #
    # Since 0.17 the file is read by `ruby_llm`'s own parser (`RubyLLM::Skill`),
    # which follows the Agent Skills specification: `name` and `description` are
    # required, the name is lower-case letters, digits and single hyphens and
    # must match the folder, and the lengths are bounded. Nexo adds only what it
    # needs on top: the three file lists, which Skills.materialize copies into a
    # sandbox.
    #
    # What Nexo does NOT take from `ruby_llm` is how a skill reaches the model.
    # `ruby_llm` attaches a `load_skill` tool that reads skill files from the
    # host when the model asks; Nexo puts #content into the agent's instructions
    # and gives the model nothing to call (see Agent#chat).
    #
    # DEPRECATED, removed in 0.18: a skill named with underscores
    # (`email_triage`) is not valid under the specification. It still loads,
    # through the reader Nexo had before 0.17, and prints a notice naming the
    # rename.
    class Skill
      # The file every skill folder holds.
      FILE = "SKILL.md"

      # The folders of files a skill may ship beside its instructions.
      KINDS = %w[scripts assets references].freeze

      FRONT_MATTER = /\A---[ \t]*\r?\n(.*?)^---[ \t]*(?:\r?\n|\z)/m
      private_constant :FRONT_MATTER

      # The skill folder's absolute path.
      attr_reader :path

      # The skill's `name`, `description` and optional `compatibility` note.
      attr_reader :name, :description, :compatibility

      # The front matter's `metadata` mapping (empty when there is none).
      attr_reader :metadata

      # The instructions: everything after the front matter.
      attr_reader :content

      # Reads the skill in the folder at `path`. Raises Nexo::Error when the
      # folder has no `SKILL.md` or the file is not a valid skill.
      def initialize(path)
        @path = File.expand_path(path.to_s)
        file = File.join(@path, FILE)
        raise Error, "skill not found: #{file}" unless File.file?(file)

        legacy_name?(file) ? read_legacy(file) : read(file)
      end

      # The files under `scripts/`, as absolute paths.
      def scripts = files("scripts")

      # The files under `assets/`, as absolute paths.
      def assets = files("assets")

      # The files under `references/`, as absolute paths.
      def references = files("references")

      private

      # Reads the skill through `ruby_llm`'s parser.
      def read(file)
        parsed = ::RubyLLM::Skill.new(@path)
        @name = parsed.name
        @description = parsed.description
        @compatibility = parsed.compatibility
        @metadata = parsed.metadata || {}
        @content = parsed.instructions.to_s.strip
      rescue ::RubyLLM::InvalidSkillError, ::RubyLLM::SkillNotFoundError => e
        raise Error, e.message
      end

      # Whether the folder or the declared name uses an underscore, the one
      # thing the specification refuses that Nexo accepted before 0.17.
      def legacy_name?(file)
        return true if File.basename(@path).include?("_")

        File.foreach(file).first(20).any? { |line| line.match?(/\Aname:\s*['"]?[^'"\s]*_/) }
      end

      # Reads an underscore-named skill the way Nexo did before 0.17, and says so once.
      def read_legacy(file)
        front_matter, @content = legacy_parse(File.read(file, encoding: "UTF-8"), file)
        @name = front_matter["name"]
        @description = front_matter["description"]
        @compatibility = front_matter["compatibility"]
        @metadata = front_matter["metadata"].is_a?(Hash) ? front_matter["metadata"] : {}
        return unless Nexo.first_warning?(:"skill-name:#{@path}")

        proper = File.basename(@path).tr("_", "-")
        Nexo.notice "[nexo] skill `#{File.basename(@path)}` (#{@path}) is named with underscores, which the " \
          "Agent Skills specification does not allow. Rename the folder and its `name:` to `#{proper}`; " \
          "`skills :#{File.basename(@path)}` keeps working. Underscore names stop loading in 0.18."
      end

      # The front matter (String keys) and the body of a legacy skill file.
      def legacy_parse(text, file)
        match = FRONT_MATTER.match(text.delete_prefix("\u{FEFF}"))
        raise Error, "#{file} must start with YAML front matter between --- lines" unless match

        front_matter = YAML.safe_load(match[1], permitted_classes: [Date, Time], aliases: false)
        raise Error, "#{file} front matter must be a YAML mapping" unless front_matter.is_a?(Hash)

        [front_matter.transform_keys(&:to_s), match.post_match.strip]
      rescue Psych::Exception => e
        raise Error, "#{file} has invalid YAML front matter: #{e.message}"
      end

      # The files under the skill's `kind` folder, as sorted absolute paths.
      def files(kind)
        dir = File.join(path, kind)
        return [] unless File.directory?(dir)

        Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) && File.basename(f) != ".keep" }.sort
      end
    end
  end
end
