# frozen_string_literal: true

module Nexo
  module Tools
    # Lists workspace files matching a glob pattern. Authorizes +:glob+ first;
    # a denial is returned as +{ error: ... }+.
    class Glob < RubyLLM::Tool
      description "List files in the workspace matching a glob pattern."
      param :pattern, type: :string, required: true, desc: "Glob pattern, e.g. **/*.rb"

      def initialize(sandbox:, permissions:)
        @sandbox = sandbox
        @permissions = permissions
        super()
      end

      def execute(pattern:)
        @permissions.authorize!(:glob, pattern)
        {files: @sandbox.glob(pattern)}
      rescue Permissions::Denied => e
        {error: e.message}
      end
    end
  end
end
