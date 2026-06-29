# frozen_string_literal: true

module Nexo
  module Tools
    # Writes content to a file in the agent's sandbox. Authorizes +:write+ first;
    # a denial is returned as +{ error: ... }+ (and nothing is written).
    class WriteFile < RubyLLM::Tool
      description "Write content to a file in the workspace."
      param :path, type: :string, required: true, desc: "Path to the file to write"
      param :content, type: :string, required: true, desc: "Content to write"

      def initialize(sandbox:, permissions:)
        @sandbox = sandbox
        @permissions = permissions
        super()
      end

      def execute(path:, content:)
        @permissions.authorize!(:write, path)
        @sandbox.write(path, content)
        {ok: true, path: path}
      rescue Permissions::Denied => e
        {error: e.message}
      end
    end
  end
end
