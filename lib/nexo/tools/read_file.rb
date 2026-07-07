# frozen_string_literal: true

module Nexo
  module Tools
    # Reads a file from the agent's sandbox. Authorizes +:read+ before touching
    # the sandbox; a denial or a missing file is returned as +{ error: ... }+ so
    # the model can adapt instead of the loop crashing.
    class ReadFile < RubyLLM::Tool
      description "Read a file from the workspace."
      param :path, type: :string, required: true, desc: "Path to the file to read"

      # +tracker:+ is an optional {ReadTracker} shared with {Tools::WriteFile}
      # for the read-before-write + stale guard. Default +nil+ ⇒ nothing is
      # recorded, preserving direct-construction behavior.
      def initialize(sandbox:, permissions:, tracker: nil)
        @sandbox = sandbox
        @permissions = permissions
        @tracker = tracker
        super()
      end

      def execute(path:)
        @permissions.authorize!(:read, path)
        content = @sandbox.read(path)
        @tracker&.record(path, @sandbox.mtime(path))
        content
      rescue Permissions::Denied, Errno::ENOENT => e
        {error: e.message}
      end
    end
  end
end
