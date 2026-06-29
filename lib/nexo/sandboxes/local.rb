# frozen_string_literal: true

require "open3"
require "fileutils"
require "timeout"

module Nexo
  module Sandboxes
    # Host filesystem + shell sandbox, for trusted dev/CI use. The developer opts
    # into this explicitly (the default is {Virtual}); two guards keep a
    # model-driven agent contained:
    #
    # * Path-escape guard — every +read+/+write+ path is expanded against +cwd+
    #   and must stay inside it, otherwise +SecurityError+ is raised.
    # * Narrowed ENV — the shell sees only PATH, HOME, LANG (plus explicit
    #   +env:+ additions), never the full process environment.
    class Local < Sandbox
      attr_reader :cwd

      def initialize(cwd: Dir.pwd, env: {})
        @cwd = File.expand_path(cwd)
        # Deliberately narrow env — never hand a model-driven shell the whole ENV.
        @env = ENV.to_h.slice("PATH", "HOME", "LANG").merge(env)
      end

      def read(path)
        File.read(absolute(path))
      end

      def glob(pattern)
        Dir.glob(File.join(@cwd, pattern))
      end

      def write(path, content)
        full = absolute(path)
        FileUtils.mkdir_p(File.dirname(full))
        File.write(full, content)
      end

      def shell(command, timeout: 30)
        # ruby_llm's target Ruby has no `timeout:` kwarg on Open3.capture3
        # (verified), so the wall-clock bound lives in Timeout.timeout.
        out, err, status = Timeout.timeout(timeout) do
          Open3.capture3(@env, command, chdir: @cwd)
        end
        {stdout: out, stderr: err, status: status.exitstatus}
      end

      private

      def absolute(path)
        full = File.expand_path(path, @cwd)
        unless full == @cwd || full.start_with?(@cwd + File::SEPARATOR)
          raise SecurityError, "path escapes sandbox: #{path}"
        end
        full
      end
    end
  end
end
