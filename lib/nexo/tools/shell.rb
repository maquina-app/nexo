# frozen_string_literal: true

module Nexo
  module Tools
    # Runs a shell command in the agent's sandbox. Authorizes +:shell+ first.
    # A denial, or a sandbox with no shell (e.g. Sandboxes::Virtual), is
    # returned as +{ error: ... }+ rather than raised into the loop.
    class Shell < RubyLLM::Tool
      description "Run a shell command in the agent's workspace."
      param :command, type: :string, required: true, desc: "The command to execute"

      # +sandbox+ runs the command; +permissions+ gates the +:shell+ capability.
      def initialize(sandbox:, permissions:)
        @sandbox = sandbox
        @permissions = permissions
        super()
      end

      # Authorizes +:shell+, runs +command+, and returns +{ stdout:, stderr:,
      # status: }+ (stdout/stderr truncated via OutputTruncator) — or
      # +{ error: ... }+ on a denial or a sandbox with no shell.
      def execute(command:)
        @permissions.authorize!(:shell, command)
        out = @sandbox.shell(command)
        {
          stdout: OutputTruncator.call(out[:stdout]),
          stderr: OutputTruncator.call(out[:stderr]),
          status: out[:status]
        }
      rescue Permissions::Denied, NotImplementedError => e
        {error: e.message}
      end
    end
  end
end
