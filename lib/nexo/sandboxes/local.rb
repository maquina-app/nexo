# frozen_string_literal: true

require "open3"
require "fileutils"
require "timeout"

module Nexo
  module Sandboxes
    # Host filesystem + shell sandbox, for trusted dev/CI use. The developer opts
    # into this explicitly (the default is Virtual); two guards keep a
    # model-driven agent contained:
    #
    # * Path-escape guard — every +read+/+write+ path is expanded against +cwd+
    #   and must stay inside it, otherwise +SecurityError+ is raised.
    # * Narrowed ENV — the shell sees only PATH, HOME, LANG (plus explicit
    #   +env:+ additions), never the full process environment.
    #
    # Under a fiber reactor (Spec 5) these blocking file/shell syscalls would
    # stall every other concurrent fiber. When +Nexo.config.concurrency == :async+
    # each operation is offloaded to a worker thread (see #offload); otherwise
    # it runs inline, byte-for-byte the Spec 1 behavior with zero overhead. The
    # offload never changes return values or the security properties below.
    class Local < Sandbox
      # The expanded workspace root; every path is guarded to stay inside it.
      attr_reader :cwd

      # Roots the sandbox at +cwd+ (expanded, default +Dir.pwd+) and narrows the
      # shell environment to +PATH+/+HOME+/+LANG+ plus any explicit +env:+ entries.
      def initialize(cwd: Dir.pwd, env: {})
        @cwd = File.expand_path(cwd)
        # The physical root (symlinks resolved), used by the escape guards so a
        # symlink inside cwd can't leak a target outside it.
        @real_cwd = File.exist?(@cwd) ? File.realpath(@cwd) : @cwd
        # Deliberately narrow env — never hand a model-driven shell the whole ENV.
        @env = ENV.to_h.slice("PATH", "HOME", "LANG").merge(env)
      end

      def read(path)
        offload { File.read(absolute(path)) }
      end

      def glob(pattern)
        # Guard the pattern itself so it can't escape via "../.." (metacharacters
        # like * are preserved by expand_path), then drop any match whose real
        # path (symlinks resolved) lands outside the sandbox.
        full = File.expand_path(pattern, @cwd)
        unless within?(full, @cwd)
          raise SecurityError, "glob pattern escapes sandbox: #{pattern}"
        end
        offload { Dir.glob(full) }.select { |match| real_within?(match) }
      end

      def write(path, content)
        offload do
          full = absolute(path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end
      end

      # A plain-text description of this host environment for the agent's system
      # prompt: the host cwd, that the real host filesystem and shell are
      # reachable, and that access is guarded to +cwd+.
      def instructions
        "You run on the host machine, cwd #{@cwd}. The real host filesystem " \
          "and shell are reachable; file access is guarded to #{@cwd}."
      end

      # Supports all four capabilities — unlike Virtual, a real process runs
      # the shell command here.
      def supports?(cap)
        %i[read write shell glob].include?(cap)
      end

      # The last-modified time of +path+ (guarded against escaping +cwd+), or
      # +nil+ when the file is absent — so a new-file write skips the
      # read-before-write guard.
      def mtime(path)
        full = absolute(path)
        File.exist?(full) ? File.mtime(full) : nil
      end

      def shell(command, timeout: 30)
        offload do
          # ruby_llm's target Ruby has no `timeout:` kwarg on Open3.capture3
          # (verified), so the wall-clock bound lives in Timeout.timeout.
          out, err, status = Timeout.timeout(timeout) do
            Open3.capture3(@env, command, chdir: @cwd)
          end
          {stdout: out, stderr: err, status: status.exitstatus}
        end
      end

      private

      # Runs a blocking block off the reactor when async concurrency is enabled,
      # inline otherwise. The decision is driven by config, not by
      # +Fiber.scheduler+ detection: under +:async+ the block runs on a worker
      # thread so the reactor keeps serving other fibers; under +:threaded+ (the
      # default) it runs inline — identical to Spec 1, zero overhead.
      #
      # +Async::WorkerPool+ is not available in the installed +async+ (2.x), so
      # the offload primitive is +Thread.new(&block).value+, which always works
      # and re-raises any exception from the block in the calling fiber (so the
      # path-escape +SecurityError+ still propagates unchanged).
      def offload(&block)
        if Nexo.config.concurrency == :async
          thread = Thread.new(&block)
          # #value re-raises any block exception (e.g. the path-escape
          # SecurityError) in the caller; silence the thread's own duplicate
          # report so an expected, re-raised error isn't printed to stderr.
          thread.report_on_exception = false
          thread.value
        else
          block.call
        end
      end

      def absolute(path)
        full = File.expand_path(path, @cwd)
        # Check the PHYSICAL location (symlinks resolved), not the lexical path, so
        # a symlink inside cwd pointing outside it — including a dangling one a
        # write would follow — can't escape the sandbox.
        unless within?(resolved(full), @real_cwd)
          raise SecurityError, "path escapes sandbox: #{path}"
        end
        full
      end

      # True when +path+ is +base+ itself or lies beneath it (lexical prefix).
      def within?(path, base)
        path == base || path.start_with?(base + File::SEPARATOR)
      end

      # Whether an existing filesystem entry's real (symlink-resolved) path stays
      # inside the sandbox. A match that vanishes or can't be resolved is excluded.
      def real_within?(path)
        within?(File.realpath(path), @real_cwd)
      rescue
        false
      end

      # The physical path a read/write would actually touch: resolve symlinks on
      # the longest existing prefix and re-append the not-yet-existing tail, and
      # follow a dangling symlink leaf to its target (a write would). Lets the
      # escape guard see where the operation really lands, not just its spelling.
      def resolved(full)
        return File.realpath(full) if File.exist?(full)
        return resolved(File.expand_path(File.readlink(full), File.dirname(full))) if File.symlink?(full)

        parent = File.dirname(full)
        base = File.exist?(parent) ? File.realpath(parent) : resolved(parent)
        File.join(base, File.basename(full))
      end
    end
  end
end
