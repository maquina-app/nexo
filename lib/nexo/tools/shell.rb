# frozen_string_literal: true

require "timeout"

module Nexo
  # The sandbox-backed, permission-gated tools Nexo attaches to an agent's chat
  # itself: Shell, Fetch and WebSearch. Each authorizes a capability against the
  # agent's Permissions before acting and returns `{ error: ... }` on a denial
  # rather than raising into the tool loop. File tools are `ruby_llm`'s own, over
  # a SandboxFileStore.
  module Tools
    # Runs a shell command in the agent's sandbox. Authorizes `:shell` first.
    # A denial, or a sandbox with no shell (e.g. Sandboxes::Virtual), is
    # returned as `{ error: ... }` rather than raised into the loop.
    class Shell < RubyLLM::Tool
      description "Run a shell command in the agent's workspace."
      parameter :command, type: :string, required: true, description: "The command to execute"

      # `sandbox` runs the command; `permissions` gates the `:shell` capability.
      def initialize(sandbox:, permissions:)
        @sandbox = sandbox
        @permissions = permissions
        super()
      end

      # Authorizes `:shell`, runs `command`, and returns
      # `{ stdout:, stderr:, status: }` (stdout/stderr truncated via OutputTruncator) — or
      # `{ error: ... }` on a denial, a sandbox with no shell, or a command that
      # ran past the sandbox's timeout (it has been killed by then).
      def execute(command:)
        @permissions.authorize!(:shell, command)
        out = @sandbox.shell(command)
        {
          stdout: OutputTruncator.call(out[:stdout]),
          stderr: OutputTruncator.call(out[:stderr]),
          status: out[:status]
        }
      rescue Permissions::Denied, NotImplementedError, Timeout::Error => e
        {error: e.message}
      end
    end
  end
end
