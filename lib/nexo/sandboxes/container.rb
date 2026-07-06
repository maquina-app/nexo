# frozen_string_literal: true

require "open3"
require "timeout"

module Nexo
  module Sandboxes
    # Runs an agent's tools inside a throwaway OCI container via the +docker+
    # (default) or Apple +container+ CLI — shell-out only, no client gem, no
    # Compose, no image builder. Implements the four-method sandbox contract
    # (+read+/+write+/+shell+/+glob+) plus +close+ by shelling the runtime binary
    # through +Open3+, so a model-driven agent never touches the host filesystem
    # or shell directly.
    #
    # Hardened by default, every knob an explicit opt-out:
    #
    # * +--network none+ (no egress) — loosen with +network:+.
    # * +--cap-drop ALL+ — restore individual caps with +cap_add:+.
    # * +--read-only+ rootfs + an ephemeral +--tmpfs <cwd>:rw+ writable scratch —
    #   disable with +readonly_rootfs: false+.
    # * +--security-opt no-new-privileges+ (always on).
    # * +--pids-limit 512+ fork-bomb guard — override/omit with +pids_limit:+.
    # * Host binds mounted **read-only** by default; a bind is writable only when
    #   the developer says so per-bind (+{ to:, mode: :rw }+).
    #
    # Non-root is NOT forced — the image's own uid is respected; +user:+ is an
    # opt-in defense-in-depth. The hardening above applies regardless of uid.
    #
    # The container starts **lazily** on first tool use and its id is memoized.
    # Ephemeral by default: +close+ force-removes the container. With +name:+ +
    # +reconnect: true+ the container is reused across sandboxes and +close+ leaves
    # it in place.
    #
    # Argv construction is pure (+run_argv+ and the exec argv builders) so the
    # offline suite asserts the exact +Open3+ argv with no daemon. Live runs are
    # +NEXO_LIVE+-gated smoke, never a core-suite dependency.
    class Container < Sandbox
      # Maps the +runtime:+ option onto the host CLI binary. Frozen — the only two
      # supported local runtimes in v1.
      RUNTIMES = {docker: "docker", apple: "container"}.freeze

      attr_reader :cwd, :runtime, :image

      # +image:+ is required (no default image). +runtime:+ selects the binary.
      # Every other keyword loosens one hardening default; see the class docs and
      # the README hardened-defaults table.
      def initialize(image: nil, runtime: :docker, cwd: "/workspace", binds: {},
        network: :none, cap_add: [], memory: nil, cpus: nil, pids_limit: 512,
        user: nil, env: {}, name: nil, reconnect: false, readonly_rootfs: true)
        raise ConfigurationError, "container sandbox requires image:" if image.nil?

        @bin = RUNTIMES.fetch(runtime) do
          raise ConfigurationError, "unknown container runtime: #{runtime.inspect}"
        end
        @runtime = runtime
        @image = image
        @cwd = cwd
        @binds = binds
        @network = network
        @cap_add = cap_add
        @memory = memory
        @cpus = cpus
        @pids_limit = pids_limit
        @user = user
        @env = env
        @name = name || "nexo-#{Nexo.generate_run_id}"
        @reconnect = reconnect
        @readonly_rootfs = readonly_rootfs
        @cid = nil
      end

      # Returns the contents of +path+ (guarded against escaping +cwd+) as a
      # String. Raises +Errno::ENOENT+ when the file is absent, matching the other
      # sandboxes' read contract.
      def read(path)
        out = exec!("cat", "--", guard_path(path))
        raise Errno::ENOENT, path unless out[:status].zero?

        out[:stdout]
      end

      # Writes +content+ to +path+ (guarded) inside the container. Content travels
      # on stdin, never interpolated into the argv, so arbitrary bytes are safe.
      def write(path, content)
        exec_stdin!(content, "sh", "-c", 'cat > "$0"', guard_path(path))
      end

      # Returns the container paths matching the glob +pattern+ (guarded). Empty
      # output yields +[]+.
      def glob(pattern)
        script = %(for f in #{guard_path(pattern)}; do [ -e "$f" ] && echo "$f"; done)
        out = exec!("sh", "-lc", script)
        out[:stdout].split("\n")
      end

      # Runs +command+ inside the container and returns
      # +{ stdout:, stderr:, status: }+ (status is the integer exit code). The
      # wall-clock bound lives in +Timeout.timeout+ around +Open3.capture3+.
      def shell(command, timeout: 30)
        exec!("sh", "-c", command, timeout: timeout)
      end

      # Force-removes the container (ephemeral default) and clears the memo.
      # Idempotent: safe with nothing started or called more than once. With
      # +reconnect: true+ the container is left in place for a later sandbox to
      # reattach by name.
      def close
        if @cid && !@reconnect
          system(@bin, "rm", "-f", @cid, out: File::NULL, err: File::NULL)
        end
        @cid = nil
      end

      # A short, human-readable description of the execution environment for the
      # agent to inject later (consumed by the Refinements spec; until then the
      # method simply exists and is correct).
      def instructions
        "You run inside a #{@runtime} container (image #{@image}), cwd #{@cwd}, " \
          "network #{@network}. Only #{@cwd} and any :rw binds are writable."
      end

      # +true+ for the four sandbox capabilities. Unlike {Virtual}, +:shell+ is
      # supported here (a real process runs the command).
      def supports?(cap)
        %i[read write shell glob].include?(cap)
      end

      private

      # The exact +run+ argv, built purely so the offline suite can assert it with
      # no daemon. Hardened flags come first; every loosening knob appends only
      # when set.
      def run_argv
        argv = [@bin, "run", "-d", "--name", @name,
          "--network", @network.to_s,
          "--cap-drop", "ALL",
          "--security-opt", "no-new-privileges"]
        @cap_add.each { |cap| argv += ["--cap-add", cap.to_s] }
        argv += ["--read-only", "--tmpfs", "#{@cwd}:rw"] if @readonly_rootfs
        argv += ["--pids-limit", @pids_limit.to_s] unless @pids_limit.nil?
        argv += ["--memory", @memory.to_s] unless @memory.nil?
        argv += ["--cpus", @cpus.to_s] unless @cpus.nil?
        argv += ["--user", @user.to_s] unless @user.nil?
        @env.each { |key, value| argv += ["-e", "#{key}=#{value}"] }
        @binds.each { |host, dst| argv += ["-v", bind_spec(host, dst)] }
        argv += ["-w", @cwd, @image, "sleep", "infinity"]
        argv
      end

      # Builds one +-v host:ctr:mode+ spec. Binds default to +:ro+; a Hash form
      # +{ to:, mode: :rw }+ makes a single bind writable.
      def bind_spec(host, dst)
        to, mode = dst.is_a?(Hash) ? [dst.fetch(:to), dst.fetch(:mode, :ro)] : [dst, :ro]
        "#{host}:#{to}:#{mode}"
      end

      # Lazily starts (or, when reconnecting, reuses) the container and memoizes
      # its id. Raises {Nexo::Error} on a start failure.
      #
      # VERIFY-before-merge (Group 0, needs a live daemon): the inspect-by-name and
      # start-if-stopped commands are encoded as sketched from the reference CLI
      # mapping. Confirm +docker ps -aqf name=<name>+ / +docker start <id>+ and the
      # Apple +container+ equivalents against a running daemon before the reconnect
      # path is trusted.
      def ensure_started!
        return @cid if @cid

        @cid = reconnect_existing if @reconnect
        return @cid if @cid

        out, err, status = Open3.capture3(*run_argv)
        raise Nexo::Error, "container start failed: #{err.strip}" unless status.success?

        @cid = out.strip
      end

      # Reconnect path: find a container previously created under +@name+ and, if
      # present, restart it (a no-op when already running) and reuse its id.
      # Returns nil when no such container exists, so +ensure_started!+ falls
      # through to a fresh +run+. Errors here fail open to the create path.
      def reconnect_existing
        out, _err, status = Open3.capture3(@bin, "ps", "-aqf", "name=#{@name}")
        return nil unless status.success?

        id = out.strip.split("\n").first
        return nil if id.nil? || id.empty?

        system(@bin, "start", id, out: File::NULL, err: File::NULL)
        id
      rescue
        nil
      end

      # Runs +cmd+ inside the started container, wall-clock bounded. Returns the
      # +{ stdout:, stderr:, status: }+ shape (integer exit code) proven by
      # {Local#shell}; +Open3.capture3+ has no +timeout:+ kwarg on the target Ruby.
      def exec!(*cmd, timeout: 30)
        ensure_started!
        out, err, status = Timeout.timeout(timeout) do
          Open3.capture3(*exec_argv(*cmd))
        end
        {stdout: out, stderr: err, status: status.exitstatus}
      end

      # As {#exec!}, but feeds +data+ to the command on stdin (used by +write+ so
      # file contents never enter the argv). +-i+ keeps stdin open.
      def exec_stdin!(data, *cmd, timeout: 30)
        ensure_started!
        out, err, status = Timeout.timeout(timeout) do
          Open3.capture3(*exec_argv(*cmd, interactive: true), stdin_data: data)
        end
        {stdout: out, stderr: err, status: status.exitstatus}
      end

      # The +exec+ argv (pure, offline-assertable). +interactive:+ inserts +-i+.
      def exec_argv(*cmd, interactive: false)
        argv = [@bin, "exec"]
        argv << "-i" if interactive
        argv += [@cid, *cmd]
        argv
      end

      # Local's path-escape guard, applied to the CONTAINER path: expand against
      # +cwd+ and raise +SecurityError+ if it escapes. Runs before any +exec+.
      def guard_path(path)
        full = File.expand_path(path, @cwd)
        unless full == @cwd || full.start_with?(@cwd + File::SEPARATOR)
          raise SecurityError, "path escapes sandbox: #{path}"
        end
        full
      end
    end
  end
end
