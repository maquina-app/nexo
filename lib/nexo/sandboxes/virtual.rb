# frozen_string_literal: true

module Nexo
  module Sandboxes
    # In-memory sandbox with zero host access — the safe default. Files live in a
    # Hash keyed by normalized absolute path, so nothing the model writes ever
    # touches the host filesystem.
    #
    # +#shell+ raises +NotImplementedError+ on purpose: in-memory means there is
    # no process to run a command in. That is the safety property, not a gap.
    class Virtual < Sandbox
      # Starts an empty in-memory filesystem rooted at +cwd+ (default +/workspace+).
      def initialize(cwd: "/workspace")
        @cwd = cwd
        @files = {}
      end

      def read(path)
        @files.fetch(norm(path)) { raise Errno::ENOENT, path }
      end

      def write(path, content)
        @files[norm(path)] = content
      end

      def glob(pattern)
        normalized = norm(pattern)
        @files.keys.select { |key| File.fnmatch(normalized, key) }
      end

      def shell(_command, **)
        raise NotImplementedError, "virtual sandbox has no shell"
      end

      private

      def norm(path)
        File.expand_path(path, @cwd)
      end
    end
  end
end
