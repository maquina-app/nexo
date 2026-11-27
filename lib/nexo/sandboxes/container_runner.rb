# frozen_string_literal: true

module Nexo
  module Sandboxes
    # Runs ONE command in a throwaway container and answers `ruby_llm`'s sandbox
    # contract (`supported?` and `run`), so a Docker- or Apple-`container`-backed
    # sandbox works anywhere that contract is accepted:
    #
    # ```ruby
    # runner = Nexo::Sandboxes::ContainerRunner.new(image: "ruby:3.3-slim")
    #
    # # ruby_llm's own code execution, for any ruby_llm app:
    # RubyLLM.configure { |config| config.sandbox = runner }
    #
    # # or as the isolation behind Nexo's local shell:
    # class Builder < Nexo::Agent
    #   sandbox :local, isolation: runner
    # end
    # ```
    #
    # It is not a Nexo::Sandbox: it has no files of its own and keeps no container
    # between calls. Every `run` is a fresh `<runtime> run --rm`, hardened like
    # Sandboxes::Container (no network, all capabilities dropped,
    # no-new-privileges, read-only root filesystem, a pids limit), with the paths
    # the caller grants bound in at the SAME path they have on the host —
    # `readable:` read-only, `writable:` read-write. Nothing else of the host is
    # visible. Sandboxes::Container remains the choice when an agent needs a
    # workspace that lives as long as the agent does.
    #
    # Limits, stated plainly:
    #
    # * `network:` from the contract (`{allow: [...]}`, which `ruby_llm` passes to
    #   install declared packages) is not honoured: a container CLI cannot express
    #   a host allow-list, so every run keeps the network this runner was built
    #   with — none by default. Package installs therefore fail unless you build
    #   the runner with `network: :bridge`, which allows ALL egress.
    # * `denied:` hides a path by mounting an empty filesystem (a directory) or
    #   `/dev/null` (a file) over it.
    # * Output is returned whole, not streamed; a block given to `run` is ignored.
    # * Granted paths must exist on the host and be shared with the runtime's VM
    #   (on macOS, Docker Desktop and OrbStack share the home directory and
    #   `/private`; other locations may not be).
    #
    # VERIFIED (ruby_llm 2.2.3, Docker 29 through OrbStack): used as
    # `Sandboxes::Local`'s `isolation:`, a command wrote inside the granted
    # directory, could not see the rest of the host, and had no network.
    class ContainerRunner
      # What `run` returns: the contract's `stdout`, `stderr`, `exit_code` and
      # `timed_out?`.
      Result = Struct.new(:stdout, :stderr, :exit_code, :timed_out) do
        # Whether the command was killed for running past its timeout.
        def timed_out? = timed_out
      end

      # Builds a runner for `image` on `runtime` (`:docker` or `:apple`). `network:`
      # is the container network every run gets (default `:none`); `memory:`,
      # `cpus:`, `pids_limit:` and `user:` are passed to the runtime as they are
      # for Sandboxes::Container. Raises ConfigurationError without an image or
      # for an unknown runtime.
      def initialize(image:, runtime: :docker, network: :none, memory: nil, cpus: nil, pids_limit: 512, user: nil)
        raise ConfigurationError, "container runner requires image:" if image.to_s.empty?

        @bin = Container::RUNTIMES.fetch(runtime) do
          raise ConfigurationError, "unknown container runtime: #{runtime.inspect}"
        end
        @runtime = runtime
        @image = image
        @network = network
        @memory = memory
        @cpus = cpus
        @pids_limit = pids_limit
        @user = user
      end

      # Whether the runtime's CLI is installed and its daemon answers. Docker's
      # `version` asks the daemon; Apple's `container` only answers for its
      # service through `system status` (VERIFIED, `container` 1.7.1).
      def supported?
        probe = (@runtime == :apple) ? %w[system status] : %w[version]
        system(@bin, *probe, out: File::NULL, err: File::NULL) ? true : false
      end

      # Why #supported? is false, for the error a caller raises.
      def reason
        "The #{@bin} CLI is not installed or its daemon is not running."
      end

      # Runs `command` — one String for the shell, or a program and its arguments —
      # in a fresh container and returns a Result. The command and its container
      # are killed when `timeout` seconds pass.
      def run(*command, timeout:, readable: [], writable: [], denied: [], directory: nil, env: {}, network: nil)
        name = "nexo-run-#{Nexo.generate_run_id}"
        argv = run_argv(name, command, readable: readable, writable: writable, denied: denied,
          directory: directory, env: env)
        # The CLI needs the host's own environment (its socket and config), so it
        # is passed on whole; the COMMAND sees only `env:`, through `-e`.
        stdout, stderr, status = Subprocess.capture(ENV.to_h, *argv, timeout: timeout)
        Result.new(stdout, stderr, status, false)
      rescue Timeout::Error => e
        # Killing the CLI does not stop the container it started.
        system(@bin, "rm", "-f", name, out: File::NULL, err: File::NULL)
        Result.new("", e.message, nil, true)
      end

      private

      # The exact `run` argv, built purely so the offline suite can assert it with
      # no daemon. Every element is its own argv entry — nothing is interpolated
      # into a shell string on the host.
      def run_argv(name, command, readable:, writable:, denied:, directory:, env:)
        argv = [@bin, "run", "--rm", "--name", name, "--network", @network.to_s, "--cap-drop", "ALL"]
        # Apple's CLI reports image and start progress on stderr unless told not to.
        argv += ["--progress", "none"] if @runtime == :apple
        argv += ["--security-opt", "no-new-privileges"] if @runtime == :docker
        argv += ["--read-only", "--tmpfs", "/tmp:rw"]
        argv += ["--pids-limit", @pids_limit.to_s] if @pids_limit && @runtime == :docker
        argv += ["--memory", @memory.to_s] unless @memory.nil?
        argv += ["--cpus", @cpus.to_s] unless @cpus.nil?
        argv += ["--user", @user.to_s] unless @user.nil?
        argv += mounts(readable, writable, denied)
        env.each { |key, value| argv += ["-e", "#{key}=#{value}"] }
        argv += ["-w", directory.to_s] if directory
        argv << @image
        argv + ((command.size == 1) ? ["sh", "-c", command.first.to_s] : command.map(&:to_s))
      end

      # Bind mounts for the granted paths, each at its own host path. A path in
      # both lists is writable. Denied paths come last so they cover what was
      # granted around them.
      def mounts(readable, writable, denied)
        writable = writable.map(&:to_s).uniq
        readable = readable.map(&:to_s).uniq - writable
        readable.flat_map { |path| ["-v", "#{path}:#{path}:ro"] } +
          writable.flat_map { |path| ["-v", "#{path}:#{path}:rw"] } +
          denied.map(&:to_s).uniq.flat_map { |path| hide(path) }
      end

      # Covers `path` with nothing: an empty tmpfs over a directory, `/dev/null`
      # over a file.
      def hide(path)
        File.directory?(path) ? ["--tmpfs", "#{path}:ro"] : ["-v", "/dev/null:#{path}:ro"]
      end
    end
  end
end
