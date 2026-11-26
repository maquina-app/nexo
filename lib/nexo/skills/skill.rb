# frozen_string_literal: true

require "yaml"

module Nexo
  module Skills
    # One skill package read from disk: a folder holding a `SKILL.md` (YAML front
    # matter + Markdown body) and, optionally, `scripts/`, `assets/` and
    # `references/`.
    #
    # This is a deliberately small reader. `ruby_llm` ships its own
    # `RubyLLM::Skill`, but it enforces the Agent Skills naming rule (lowercase
    # words joined by hyphens, equal to the folder name), which rejects the
    # underscore names Nexo has always resolved from a symbol (`skills
    # :email_triage`). Nexo only ever needs the body text and the file listings,
    # so it reads those itself rather than force every host to rename its skills.
    class Skill
      # The file that makes a folder a skill.
      FILE = "SKILL.md"

      # The bundled-file folders a skill may ship.
      KINDS = %w[scripts assets references].freeze

      FRONT_MATTER = /\A---[ \t]*\r?\n(.*?)^---[ \t]*(?:\r?\n|\z)/m
      private_constant :FRONT_MATTER

      # The skill's folder, as an absolute path String.
      attr_reader :path

      # The front matter as a Hash with String keys.
      attr_reader :metadata

      # The `SKILL.md` body: the instructions injected into the chat.
      attr_reader :content

      # Reads the skill in the folder `path`. Raises Nexo::Error naming the file
      # when `SKILL.md` is missing, has no front matter, or its front matter is
      # not a YAML mapping.
      def initialize(path)
        @path = File.expand_path(path.to_s)
        file = File.join(@path, FILE)
        raise Error, "skill not found: #{file}" unless File.file?(file)

        @metadata, @content = parse(File.read(file, encoding: "UTF-8"), file)
      end

      # The skill's declared name.
      def name = metadata["name"]

      # The one-line summary of when to use the skill.
      def description = metadata["description"]

      # What the skill needs from its environment, or nil when it declares nothing.
      def compatibility = metadata["compatibility"]

      # Host paths of the files under `scripts/`, sorted.
      def scripts = files("scripts")

      # Host paths of the files under `assets/`, sorted.
      def assets = files("assets")

      # Host paths of the files under `references/`, sorted.
      def references = files("references")

      private

      # Splits `text` into its front matter Hash and its Markdown body.
      def parse(text, file)
        match = FRONT_MATTER.match(text.delete_prefix("\u{FEFF}"))
        raise Error, "#{file} must start with YAML front matter between --- lines" unless match

        front_matter = YAML.safe_load(match[1], permitted_classes: [Date, Time], aliases: false)
        raise Error, "#{file} front matter must be a YAML mapping" unless front_matter.is_a?(Hash)

        [front_matter.transform_keys(&:to_s), match.post_match.strip]
      rescue Psych::Exception => e
        raise Error, "#{file} has invalid YAML front matter: #{e.message}"
      end

      # The files under one of the skill's folders, as sorted host paths.
      def files(kind)
        dir = File.join(path, kind)
        return [] unless File.directory?(dir)

        Dir.glob(File.join(dir, "**", "*")).select { |f| File.file?(f) && File.basename(f) != ".keep" }.sort
      end
    end
  end
end
