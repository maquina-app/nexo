# frozen_string_literal: true

require "fileutils"
require "timeout"

module Nexo
  module Sandboxes
    # Host filesystem + shell sandbox, for trusted dev/CI use. The developer opts
    # into this explicitly (the default is Virtual). What keeps a model-driven
    # agent contained:
    #
    # * Path-escape guard — every `read`/`write` path is expanded against `cwd`
    #   and must stay inside it, otherwise `SecurityError` is raised.
    # * Narrowed ENV — the shell sees only PATH, HOME, LANG (plus explicit
    #   `env:` additions), never the full process environment.
    # * A real timeout — a command that outlives `timeout:` is killed together
    #   with everything it started.
    #
    # ⚠️ The path guard covers `read`/`write`/`glob` only. A shell command is a
    # host process: unless `isolation: :confined` is set it can read and write
    # anywhere the user can, and reach the network. #hardening_gaps reports this
    # so a host can show it.
    #
    # ## Confining the shell
    #
    # `isolation: :confined` runs each command inside an OS sandbox (Seatbelt on
    # macOS, Bubblewrap on Linux) through `ruby_llm`'s sandbox contract, so it can
    # write only inside `cwd`, cannot read the home directory, and has no network.
    # It needs the `mxc` gem (a soft dependency: add `gem "mxc"` to the host
    # Gemfile). A confined command cannot read outside `cwd` either, which
    # includes a Ruby or Node installed under the home directory — grant those
    # with `readable:`. `readable: :ruby` grants the running Ruby and its gems
    # (see ::ruby_paths).
    #
    # ```ruby
    # sandbox :local, isolation: :confined, readable: :ruby
    # ```
    #
    # `isolation:` also takes any object answering `ruby_llm`'s sandbox contract
    # (`supported?` and `run`), or an `MXC::Sandbox` class or instance carrying a
    # policy of your own.
    #
    # Under a fiber reactor (Spec 5) these blocking file/shell syscalls would
    # stall every other concurrent fiber. When `Nexo.config.concurrency == :async`
    # each operation is offloaded to a worker thread (see #offload); otherwise
    # it runs inline with zero overhead. The offload never changes return values
    # or the security properties above.
    class Local < Sandbox
      # The expanded workspace root; every path is guarded to stay inside it.
      attr_reader :cwd

      # How the shell is isolated: `:none`, `:confined`, or the sandbox object given.
      attr_reader :isolation

      # The directories a confined command must be able to read to run the Ruby
      # this process runs on, with its standard library and installed gems: the
      # interpreter's prefix and every gem path. `readable: :ruby` expands to
      # them, which is what a confined `ruby script.rb` or `bundle exec` needs —
      # a confined command can otherwise read only `cwd`.
      #
      # ```ruby
      # sandbox :local, isolation: :confined, readable: :ruby
      # ```
      def self.ruby_paths
        [RbConfig::CONFIG["prefix"], *Gem.path, Gem.default_dir]
          .compact.map { |path| File.expand_path(path) }.uniq
      end

      # Roots the sandbox at `cwd` (expanded, default `Dir.pwd`) and narrows the
      # shell environment to `PATH`/`HOME`/`LANG` plus any explicit `env:` entries.
      #
      # `isolation:` is `:none` (default — the shell is an ordinary host process),
      # `:confined` (an OS sandbox through the `mxc` gem), or a sandbox object.
      # `readable:` lists extra paths a confined command may read; the symbol
      # `:ruby` stands for ::ruby_paths. Raises
      # ConfigurationError for an unknown `isolation:`; a `:confined` sandbox that
      # cannot run on this machine raises on the first #shell, not here.
      def initialize(cwd: Dir.pwd, env: {}, isolation: :none, readable: [])
        @cwd = File.expand_path(cwd)
        # The physical root (symlinks resolved), used by the escape guards so a
        # symlink inside cwd can't leak a target outside it.
        @real_cwd = File.exist?(@cwd) ? File.realpath(@cwd) : @cwd
        # Deliberately narrow env — never hand a model-driven shell the whole ENV.
        @env = ENV.to_h.slice("PATH", "HOME", "LANG").merge(env.transform_keys(&:to_s))
        @isolation = isolation
        @readable = Array(readable).flat_map { |path| (path == :ruby) ? self.class.ruby_paths : File.expand_path(path.to_s) }.uniq
        return if %i[none confined].include?(isolation) || contract?(isolation) || mxc_sandbox?(isolation)

        raise Nexo::ConfigurationError,
          "unknown isolation #{isolation.inspect} (use :none, :confined, or a sandbox object)"
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

      # Every regular file under `cwd`, relative to it. `Dir.glob` skips dotfiles
      # by default, and a symlink whose target is outside the sandbox is left out.
      def files
        offload do
          Dir.glob("**/*", base: @cwd).select do |path|
            full = File.join(@cwd, path)
            File.file?(full) && real_within?(full)
          end.sort
        end
      end

      # The size of `path` in bytes, without reading it.
      def file_size(path)
        File.size(absolute(path))
      end

      def write(path, content)
        offload do
          full = absolute(path)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end
      end

      # A plain-text description of this host environment for the agent's system
      # prompt: the host cwd, and what a shell command can and cannot reach.
      def instructions
        if confined?
          "You run on the host machine, cwd #{@cwd}. File access is guarded to " \
            "#{@cwd}. Shell commands run in an OS sandbox: they can write only " \
            "inside #{@cwd} and have no network access."
        else
          "You run on the host machine, cwd #{@cwd}. The real host filesystem " \
            "and shell are reachable; file access is guarded to #{@cwd}."
        end
      end

      # Whether shell commands run inside an OS sandbox.
      def confined? = @isolation != :none

      # What this sandbox does NOT contain, as short human-readable strings — the
      # same contract as Container#hardening_gaps. Empty when the shell is confined.
      def hardening_gaps
        return [] if confined?

        ["shell commands are not confined: they can read and write outside #{@cwd} " \
          "and reach the network (set isolation: :confined, or use a container sandbox)"]
      end

      # Supports all four capabilities — unlike Virtual, a real process runs
      # the shell command here.
      def supports?(cap)
        %i[read write shell glob].include?(cap)
      end

      # The last-modified time of `path` (guarded against escaping `cwd`), or
      # `nil` when the file is absent — so a new-file write skips the
      # read-before-write guard.
      def mtime(path)
        full = absolute(path)
        File.exist?(full) ? File.mtime(full) : nil
      end

      # Runs `command` through `sh`, in `cwd`, with the narrowed environment.
      # Raises `Timeout::Error` after `timeout` seconds — and by then the command
      # and every process it started have been killed.
      def shell(command, timeout: 30)
        offload { confined? ? confined_shell(command, timeout) : host_shell(command, timeout) }
      end

      private

      # The unconfined path: an ordinary host process, given ONLY the narrowed
      # environment and killed with everything it started when the timeout fires
      # (see Subprocess).
      def host_shell(command, timeout)
        stdout, stderr, status = Subprocess.capture(@env, command, timeout: timeout, chdir: @cwd)
        {stdout: stdout, stderr: stderr, status: status}
      end

      # The confined path: `ruby_llm`'s sandbox contract. The runner adds this
      # run's grants (cwd readable and writable, the declared `readable:` paths)
      # to its own policy; `network: nil` keeps that policy's network access,
      # which is none for the default sandbox.
      def confined_shell(command, timeout)
        result = runner.run("sh", "-c", command, timeout: timeout, directory: @real_cwd,
          readable: [@real_cwd, *@readable], writable: [@real_cwd], env: @env, network: nil)
        raise Timeout::Error, "command timed out after #{timeout}s and was killed" if result.timed_out?

        {stdout: result.stdout.to_s, stderr: result.stderr.to_s, status: result.exit_code}
      end

      # The object that runs a confined command, resolved once. Raises
      # ConfigurationError when it cannot run on this machine, so a host that
      # asked for confinement never silently gets an unconfined shell.
      def runner
        @runner ||= begin
          candidate = contract?(@isolation) ? @isolation : mxc_runner
          unless candidate.supported?
            reason = candidate.reason if candidate.respond_to?(:reason)
            raise Nexo::ConfigurationError,
              ["the shell sandbox cannot run on this machine.", reason].compact.join(" ")
          end
          candidate
        end
      end

      # Wraps an `MXC::Sandbox` (the default one for `:confined`, or the host's
      # own) in `ruby_llm`'s adapter, which speaks the sandbox contract.
      def mxc_runner
        require_mxc!
        ::RubyLLM::Sandbox.resolve((@isolation == :confined) ? ::MXC::Sandbox.new : @isolation)
      end

      # `mxc` is a soft dependency, like `async`: required only on this path.
      def require_mxc!
        require "mxc"
      rescue LoadError
        raise Nexo::MissingDependencyError,
          "isolation: :confined needs the mxc gem — add `gem \"mxc\"` to your Gemfile"
      end

      # Whether `value` answers `ruby_llm`'s sandbox contract.
      def contract?(value)
        value.respond_to?(:run) && value.respond_to?(:supported?)
      end

      # Whether `value` is an `MXC::Sandbox` class or instance. False when the
      # gem is not loaded: a host holding one has necessarily loaded it.
      def mxc_sandbox?(value)
        return false unless defined?(::MXC::Sandbox)

        value.is_a?(::MXC::Sandbox) || (value.is_a?(Class) && value <= ::MXC::Sandbox)
      end

      # Runs a blocking block off the reactor when async concurrency is enabled,
      # inline otherwise. The decision is driven by config, not by
      # `Fiber.scheduler` detection: under `:async` the block runs on a worker
      # thread so the reactor keeps serving other fibers; under `:threaded` (the
      # default) it runs inline — identical to Spec 1, zero overhead.
      #
      # `Async::WorkerPool` is not available in the installed `async` (2.x), so
      # the offload primitive is `Thread.new(&block).value`, which always works
      # and re-raises any exception from the block in the calling fiber (so the
      # path-escape `SecurityError` still propagates unchanged).
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

      # `path` expanded against `cwd`, or `SecurityError` when it would land
      # outside the sandbox.
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

      # True when `path` is `base` itself or lies beneath it (lexical prefix).
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
