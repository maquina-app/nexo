# frozen_string_literal: true

module Nexo
  module Tools
    # Writes content to a file in the agent's sandbox. Authorizes +:write+ first;
    # a denial is returned as +{ error: ... }+ (and nothing is written).
    class WriteFile < RubyLLM::Tool
      description "Write content to a file in the workspace."
      param :path, type: :string, required: true, desc: "Path to the file to write"
      param :content, type: :string, required: true, desc: "Content to write"

      # +tracker:+ is an optional ReadTracker shared with Tools::ReadFile.
      # Default +nil+ ⇒ the read-before-write + stale guard is off, preserving
      # direct-construction behavior byte-for-byte.
      def initialize(sandbox:, permissions:, tracker: nil)
        @sandbox = sandbox
        @permissions = permissions
        @tracker = tracker
        super()
      end

      # Authorizes +:write+, applies the read-before-write + stale guard, then
      # writes +content+ to +path+ and returns +{ ok: true, path: }+ — or
      # +{ error: ... }+ on a denial or a guard violation (nothing is written).
      def execute(path:, content:)
        @permissions.authorize!(:write, path)
        if (guard_error = clobber_guard(path))
          return {error: guard_error}
        end

        @sandbox.write(path, content)
        {ok: true, path: path}
      rescue Permissions::Denied => e
        {error: e.message}
      end

      private

      # The read-before-write + stale guard, active only on a real-filesystem
      # sandbox (non-nil +mtime+) with a tracker present. Returns an error string
      # to abort the write, or +nil+ to proceed. On Sandboxes::Virtual (nil
      # mtime) or without a tracker the guard is skipped entirely — behavior is
      # byte-for-byte the shipped tool.
      def clobber_guard(path)
        return nil if @tracker.nil?

        current = @sandbox.mtime(path)
        return nil if current.nil? # new file, or a sandbox with no mtime concept

        unless @tracker.read?(path)
          return "read #{path} before overwriting it"
        end
        if @tracker.recorded_mtime(path) != current
          return "stale: #{path} changed since you read it"
        end

        nil
      end
    end
  end
end
