# frozen_string_literal: true

module Nexo
  # The sandbox-backed, permission-gated tools Nexo attaches to an agent's chat:
  # ReadFile, WriteFile, Shell, Glob, and Fetch. Each authorizes a capability
  # against the agent's Permissions before acting and returns +{ error: ... }+ on
  # a denial rather than raising into the tool loop.
  module Tools
    # Reads a file from the agent's sandbox. Authorizes +:read+ before touching
    # the sandbox; a denial or a missing file is returned as +{ error: ... }+ so
    # the model can adapt instead of the loop crashing.
    class ReadFile < RubyLLM::Tool
      description "Read a file from the workspace."
      param :path, type: :string, required: true, desc: "Path to the file to read"

      # Returned content is capped to this many bytes (head), matching Tools::Fetch,
      # so a single huge file can't blow a small context window. The read-before-write
      # guard is unaffected — it records the file's mtime, not its content.
      MAX_BYTES = 200_000

      # +tracker:+ is an optional ReadTracker shared with Tools::WriteFile
      # for the read-before-write + stale guard. Default +nil+ ⇒ nothing is
      # recorded, preserving direct-construction behavior.
      def initialize(sandbox:, permissions:, tracker: nil)
        @sandbox = sandbox
        @permissions = permissions
        @tracker = tracker
        super()
      end

      # Authorizes +:read+, reads +path+ from the sandbox, records +(path, mtime)+
      # on the tracker (if any), and returns the content — or +{ error: ... }+ on a
      # denied read or a missing file.
      def execute(path:)
        @permissions.authorize!(:read, path)
        content = @sandbox.read(path)
        @tracker&.record(path, @sandbox.mtime(path))
        cap(content)
      rescue Permissions::Denied, Errno::ENOENT => e
        {error: e.message}
      end

      private

      # Head-truncates oversized content with a marker; leaves normal-sized files
      # (and non-String sandbox returns) untouched.
      def cap(content)
        return content unless content.is_a?(String) && content.bytesize > MAX_BYTES

        "#{content.byteslice(0, MAX_BYTES)}\n…[truncated: file exceeds #{MAX_BYTES} bytes]"
      end
    end
  end
end
