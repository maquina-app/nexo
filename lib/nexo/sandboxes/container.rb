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

      # What each runtime's CLI can actually express. Verified live against
      # +container+ 1.2.2 on macOS and Docker 29.4: Apple's CLI rejects
      # +--security-opt+ and +--pids-limit+ with "Unknown option", which aborts
      # +container run+ before the sandbox ever starts.
      #
      # +writable_tmpfs+ is not about the flag being accepted — Apple accepts
      # +--tmpfs+ — but about what it does: combined with +--read-only+ the mount is
      # NOT writable there, so a read-only rootfs leaves no usable scratch.
      #
      # Anything a runtime cannot honor is reported through #hardening_gaps rather
      # than dropped quietly: running with weaker isolation, or with a workspace you
      # cannot write to, must be visible.
      CAPABILITIES = {
        docker: {security_opt: true, pids_limit: true, writable_tmpfs: true},
        apple: {security_opt: false, pids_limit: false, writable_tmpfs: false}
      }.freeze

      # The container working directory (default +/workspace+, a container path),
      # the selected +runtime+ (+:docker+ / +:apple+), and the required +image+.
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

      # Writes +content+ to +path+ (guarded) inside the container, creating parent
      # directories first. Content travels on stdin, never interpolated into the argv,
      # so arbitrary bytes are safe.
      #
      # Matches Local#write on both counts, which it previously did not: without the
      # +mkdir+ a nested path failed with "Directory nonexistent", and because the
      # exit status was discarded the caller was told the write had succeeded. Raises
      # +IOError+ on failure, mirroring how #read raises +Errno::ENOENT+.
      def write(path, content)
        full = guard_path(path)
        out = exec_stdin!(content, "sh", "-c", 'mkdir -p "$(dirname "$0")" && cat > "$0"', full)
        raise IOError, "container write failed: #{path}: #{out[:stderr].strip}" unless out[:status].zero?

        full
      end

      # Returns the container paths matching the glob +pattern+ (guarded). Empty
      # output yields +[]+.
      #
      # The guarded pattern is passed as a positional parameter (+$1+), NEVER
      # interpolated into the script text, so shell metacharacters in a
      # model-supplied pattern (+;+, +$()+, backticks) are inert data — +for f in
      # $1+ still performs pathname (glob) expansion, but nothing in +$1+ is ever
      # parsed as a command.
      def glob(pattern)
        script = 'for f in $1; do [ -e "$f" ] && echo "$f"; done'
        out = exec!("sh", "-c", script, "sh", guard_path(pattern))
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
      # reattach by its exact identity label. Teardown stays id-based
      # (+<bin> rm -f <cid>+): the memoized id is exact and unambiguous.
      def close
        if @cid && !@reconnect
          system(@bin, "rm", "-f", @cid, out: File::NULL, err: File::NULL)
        end
        @cid = nil
      end

      # Hardening the caller asked for that this runtime cannot express, as short
      # human-readable strings. Empty on +:docker+. Callers that require a guarantee
      # should check this rather than assume every runtime honors every knob.
      def hardening_gaps
        gaps = []
        gaps << "--security-opt no-new-privileges is not supported by #{@runtime}" unless capable?(:security_opt)
        gaps << "--pids-limit is not supported by #{@runtime}" if @pids_limit && !capable?(:pids_limit)
        if @readonly_rootfs && !capable?(:writable_tmpfs)
          gaps << "#{@runtime} --tmpfs is not writable under --read-only; " \
                  "set readonly_rootfs: false or add a :rw bind for a writable workspace"
        end
        gaps
      end

      # A short, human-readable description of the execution environment for the
      # agent to inject later (consumed by the Refinements spec; until then the
      # method simply exists and is correct).
      def instructions
        "You run inside a #{@runtime} container (image #{@image}), cwd #{@cwd}, " \
          "network #{@network}. Only #{@cwd} and any :rw binds are writable."
      end

      # +true+ for the four sandbox capabilities. Unlike Virtual, +:shell+ is
      # supported here (a real process runs the command).
      def supports?(cap)
        %i[read write shell glob].include?(cap)
      end

      # The last-modified time of +path+ (guarded) inside the container, read by
      # shelling +stat -c %Y+ (GNU coreutils epoch seconds). Returns a +Time+, or
      # +nil+ when the file is absent — so a new-file write skips the
      # read-before-write guard. Used only by the R4 clobber guard.
      def mtime(path)
        out = exec!("stat", "-c", "%Y", "--", guard_path(path))
        return nil unless out[:status].zero?

        epoch = out[:stdout].strip
        epoch.empty? ? nil : Time.at(Integer(epoch))
      rescue ArgumentError
        nil
      end

      private

      # The exact +run+ argv, built purely so the offline suite can assert it with
      # no daemon. Hardened flags come first; every loosening knob appends only
      # when set.
      def run_argv
        # The identity label goes immediately after --name and before every
        # loosening/hardening knob — it is what makes an *exact* reconnect
        # possible (see #reconnect_argv). The key is exactly +nexo.sandbox.id+.
        argv = [@bin, "run", "-d", "--name", @name,
          "--label", "nexo.sandbox.id=#{@name}",
          "--network", @network.to_s,
          "--cap-drop", "ALL"]
        argv += ["--security-opt", "no-new-privileges"] if capable?(:security_opt)
        @cap_add.each { |cap| argv += ["--cap-add", cap.to_s] }
        argv += ["--read-only", "--tmpfs", "#{@cwd}:rw"] if @readonly_rootfs
        argv += ["--pids-limit", @pids_limit.to_s] if @pids_limit && capable?(:pids_limit)
        argv += ["--memory", @memory.to_s] unless @memory.nil?
        argv += ["--cpus", @cpus.to_s] unless @cpus.nil?
        argv += ["--user", @user.to_s] unless @user.nil?
        @env.each { |key, value| argv += ["-e", "#{key}=#{value}"] }
        @binds.each { |host, dst| argv += ["-v", bind_spec(host, dst)] }
        # +tail -f /dev/null+ is busybox-portable (Alpine, Debian-slim, ruby-slim
        # all hold open); +sleep infinity+ is NOT busybox-safe and exits at once
        # on a slim image, failing every later +exec+.
        argv += ["-w", @cwd, @image, "tail", "-f", "/dev/null"]
        argv
      end

      # Whether this runtime's CLI can express +knob+.
      def capable?(knob)
        CAPABILITIES.fetch(@runtime, CAPABILITIES[:docker]).fetch(knob, true)
      end

      # Builds one +-v host:ctr:mode+ spec. Binds default to +:ro+; a Hash form
      # +{ to:, mode: :rw }+ makes a single bind writable.
      def bind_spec(host, dst)
        to, mode = dst.is_a?(Hash) ? [dst.fetch(:to), dst.fetch(:mode, :ro)] : [dst, :ro]
        "#{host}:#{to}:#{mode}"
      end

      # Lazily starts (or, when reconnecting, reuses) the container and memoizes
      # its id. Raises Nexo::Error on a start failure.
      def ensure_started!
        return @cid if @cid

        @cid = reconnect_existing if @reconnect
        return @cid if @cid

        out, err, status = Open3.capture3(*run_argv)
        raise Nexo::Error, "container start failed: #{err.strip}" unless status.success?

        @cid = out.strip
      end

      # Reconnect path: find the container previously created under +@name+ by its
      # EXACT identity label (never a name substring) and, if present, restart it
      # (a no-op when already running) and reuse its id.
      #
      # * 0 matches  -> +nil+ (so +ensure_started!+ falls through to a fresh +run+).
      # * 1 match    -> +start+ it and reuse that id.
      # * >1 matches -> raise +Nexo::Error+; never guess which one to attach.
      #
      # Only genuinely unexpected errors (a daemon/CLI failure) fail open to the
      # create path; the ambiguity raise and the Apple-posture +ConfigurationError+
      # (both +Nexo::Error+ subclasses) are re-raised, never swallowed.
      #
      # Runtime isolation is inherent: the query shells the runtime-specific +@bin+
      # (docker vs. Apple +container+), and each runtime keeps its own id namespace,
      # so a +:docker+ container can never be reattached by an +:apple+ sandbox or
      # vice versa.
      def reconnect_existing
        # Apple reconnect posture (Spec 20 R4/Q4): Apple's +container+ CLI has no
        # live-verified exact +label=+ filter, and a name substring match is unsafe,
        # so reconnect on +:apple+ raises rather than risk attaching the wrong
        # container. Wire the verified mechanism here once Group 0 confirms one.
        if @runtime == :apple
          raise ConfigurationError,
            "reconnect: true is not supported on the Apple :container runtime — " \
            "it has no verified exact label filter (Spec 20 Q4); use runtime: :docker " \
            "for reconnect, or run an ephemeral :apple sandbox (reconnect: false)"
        end

        out, _err, status = Open3.capture3(*reconnect_argv)
        return nil unless status.success?

        ids = out.strip.split("\n").reject(&:empty?)
        return nil if ids.empty?
        if ids.size > 1
          raise Nexo::Error, "ambiguous reconnect: #{ids.size} containers labeled #{@name}"
        end

        system(@bin, "start", ids.first, out: File::NULL, err: File::NULL)
        ids.first
      rescue Nexo::Error
        raise
      rescue
        nil
      end

      # The exact reconnect query argv, built purely so the offline suite can assert
      # it with no daemon. Matches by the exact identity label set in +run_argv+
      # (+label=nexo.sandbox.id=<name>+), NOT a +name=<name>+ substring filter.
      def reconnect_argv
        [@bin, "ps", "-aqf", "label=nexo.sandbox.id=#{@name}"]
      end

      # Runs +cmd+ inside the started container, wall-clock bounded. Returns the
      # +{ stdout:, stderr:, status: }+ shape (integer exit code) proven by
      # Local#shell; +Open3.capture3+ has no +timeout:+ kwarg on the target Ruby.
      def exec!(*cmd, timeout: 30)
        ensure_started!
        out, err, status = Timeout.timeout(timeout) do
          Open3.capture3(*exec_argv(*cmd))
        end
        {stdout: out, stderr: err, status: status.exitstatus}
      end

      # As #exec!, but feeds +data+ to the command on stdin (used by +write+ so
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
