# frozen_string_literal: true

require "json"
require "open3"
require "securerandom"
require "timeout"

module Nexo
  module Sandboxes
    # Runs an agent's tools inside a throwaway OCI container via the `docker`
    # (default) or Apple `container` CLI — shell-out only, no client gem, no
    # Compose, no image builder. Implements the four-method sandbox contract
    # (`read`/`write`/`shell`/`glob`) plus `close` by shelling the runtime binary
    # through `Open3`, so a model-driven agent never touches the host filesystem
    # or shell directly.
    #
    # Hardened by default, every knob an explicit opt-out:
    #
    # * `--network none` (no egress) — loosen with `network:`.
    # * `--cap-drop ALL` — restore individual caps with `cap_add:`.
    # * `--read-only` rootfs + an ephemeral `--tmpfs <cwd>:rw` writable scratch —
    #   disable with `readonly_rootfs: false`.
    # * `--security-opt no-new-privileges` (always on).
    # * `--pids-limit 512` fork-bomb guard — override/omit with `pids_limit:`.
    # * Host binds mounted **read-only** by default; a bind is writable only when
    #   the developer says so per-bind (`{ to:, mode: :rw }`).
    #
    # Non-root is NOT forced — the image's own uid is respected; `user:` is an
    # opt-in defense-in-depth. The hardening above applies regardless of uid.
    #
    # The container starts **lazily** on first tool use and its id is memoized.
    # Ephemeral by default: `close` force-removes the container. With `name:` +
    # `reconnect: true` the container is reused across sandboxes and `close` leaves
    # it in place.
    #
    # Argv construction is pure (`run_argv` and the exec argv builders) so the
    # offline suite asserts the exact `Open3` argv with no daemon. Live runs are
    # `NEXO_LIVE`-gated smoke, never a core-suite dependency.
    class Container < Sandbox
      # Maps the `runtime:` option onto the host CLI binary. Frozen — the only two
      # supported local runtimes in v1.
      RUNTIMES = {docker: "docker", apple: "container"}.freeze

      # What each runtime's CLI can actually express. Verified live against
      # Docker 29 and Apple `container` 1.7.1 (0.16): Apple's CLI rejects
      # `--security-opt` and `--pids-limit` with "Unknown option", which aborts
      # `container run` before the sandbox ever starts.
      #
      # `writable_tmpfs` is not about the flag being accepted but about what it
      # does: on `container` 1.2 a `--tmpfs` under `--read-only` was NOT writable,
      # which left a read-only rootfs with no usable scratch. It is writable on
      # 1.7.1, so the gap is no longer reported; on an older `container`, set
      # `readonly_rootfs: false`.
      #
      # Anything a runtime cannot honor is reported through #hardening_gaps rather
      # than dropped quietly: running with weaker isolation, or with a workspace you
      # cannot write to, must be visible.
      CAPABILITIES = {
        docker: {security_opt: true, pids_limit: true, writable_tmpfs: true},
        apple: {security_opt: false, pids_limit: false, writable_tmpfs: true}
      }.freeze

      # The container working directory (default `/workspace`, a container path),
      # the selected `runtime` (`:docker` / `:apple`), and the required `image`.
      attr_reader :cwd, :runtime, :image

      # `image:` is required (no default image). `runtime:` selects the binary.
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

      # Returns the contents of `path` (guarded against escaping `cwd`) as a
      # String. Raises `Errno::ENOENT` when the file is absent, matching the other
      # sandboxes' read contract.
      def read(path)
        out = exec!("cat", "--", guard_path(path))
        raise Errno::ENOENT, path unless out[:status].zero?

        out[:stdout]
      end

      # Writes `content` to `path` (guarded) inside the container, creating parent
      # directories first. Content travels on stdin, never interpolated into the argv,
      # so arbitrary bytes are safe.
      #
      # Matches Local#write on both counts, which it previously did not: without the
      # `mkdir` a nested path failed with "Directory nonexistent", and because the
      # exit status was discarded the caller was told the write had succeeded. Raises
      # `IOError` on failure, mirroring how #read raises `Errno::ENOENT`.
      def write(path, content)
        full = guard_path(path)
        out = exec_stdin!(content, "sh", "-c", 'mkdir -p "$(dirname "$0")" && cat > "$0"', full)
        raise IOError, "container write failed: #{path}: #{out[:stderr].strip}" unless out[:status].zero?

        full
      end

      # Returns the container paths matching the glob `pattern` (guarded). Empty
      # output yields `[]`.
      #
      # The guarded pattern is passed as a positional parameter (`$1`), NEVER
      # interpolated into the script text, so shell metacharacters in a
      # model-supplied pattern (`;`, `$()`, backticks) are inert data —
      # `for f in $1` still performs pathname (glob) expansion, but nothing in `$1` is ever
      # parsed as a command.
      def glob(pattern)
        script = 'for f in $1; do [ -e "$f" ] && echo "$f"; done'
        out = exec!("sh", "-c", script, "sh", guard_path(pattern))
        out[:stdout].split("\n")
      end

      # Runs `command` inside the container and returns
      # `{ stdout:, stderr:, status: }` (status is the integer exit code). After
      # `timeout` seconds it raises `Timeout::Error`, with the command — and
      # whatever it started — already killed inside the container.
      def shell(command, timeout: 30)
        exec!("sh", "-c", command, timeout: timeout)
      end

      # Force-removes the container (ephemeral default) and clears the memo.
      # Idempotent: safe with nothing started or called more than once. With
      # `reconnect: true` the container is left in place for a later sandbox to
      # reattach by its exact identity label. Teardown stays id-based
      # (`<bin> rm -f <cid>`): the memoized id is exact and unambiguous.
      def close
        if @cid && !@reconnect
          system(@bin, "rm", "-f", @cid, out: File::NULL, err: File::NULL)
        end
        @cid = nil
      end

      # Hardening the caller asked for that this runtime cannot express, as short
      # human-readable strings. Empty on `:docker`. Callers that require a guarantee
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

      # `true` for the four sandbox capabilities. Unlike Virtual, `:shell` is
      # supported here (a real process runs the command).
      def supports?(cap)
        %i[read write shell glob].include?(cap)
      end

      private

      # The exact `run` argv, built purely so the offline suite can assert it with
      # no daemon. Hardened flags come first; every loosening knob appends only
      # when set.
      def run_argv
        # The identity label goes immediately after --name and before every
        # loosening/hardening knob — it is what makes an *exact* reconnect
        # possible (see #reconnect_argv). The key is exactly `nexo.sandbox.id`.
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
        # `tail -f /dev/null` is busybox-portable (Alpine, Debian-slim, ruby-slim
        # all hold open); `sleep infinity` is NOT busybox-safe and exits at once
        # on a slim image, failing every later `exec`.
        argv += ["-w", @cwd, @image, "tail", "-f", "/dev/null"]
        argv
      end

      # Whether this runtime's CLI can express `knob`.
      def capable?(knob)
        CAPABILITIES.fetch(@runtime, CAPABILITIES[:docker]).fetch(knob, true)
      end

      # Builds one `-v host:ctr:mode` spec. Binds default to `:ro`; a Hash form
      # `{ to:, mode: :rw }` makes a single bind writable.
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

      # Reconnect path: find the container previously created under `@name` by its
      # EXACT identity label (never a name substring) and, if present, restart it
      # (a no-op when already running) and reuse its id.
      #
      # * 0 matches  -> `nil` (so `ensure_started!` falls through to a fresh `run`).
      # * 1 match    -> `start` it and reuse that id.
      # * >1 matches -> raise `Nexo::Error`; never guess which one to attach.
      #
      # Only genuinely unexpected errors (a daemon/CLI failure) fail open to the
      # create path; the ambiguity raise (a `Nexo::Error`) is re-raised, never
      # swallowed.
      #
      # Runtime isolation is inherent: the query shells the runtime-specific `@bin`
      # (docker vs. Apple `container`), and each runtime keeps its own id namespace,
      # so a `:docker` container can never be reattached by an `:apple` sandbox or
      # vice versa.
      def reconnect_existing
        out, _err, status = Open3.capture3(*reconnect_argv)
        return nil unless status.success?

        ids = reconnect_ids(out)
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

      # The reconnect query argv, built purely so the offline suite can assert it
      # with no daemon. Docker filters by the exact identity label set in
      # `run_argv` (`label=nexo.sandbox.id=<name>`), NOT a `name=<name>` substring
      # filter. Apple's `container list` has no filter, so it lists every
      # container as JSON and #reconnect_ids matches the label exactly.
      def reconnect_argv
        return [@bin, "list", "--all", "--format", "json"] if @runtime == :apple

        [@bin, "ps", "-aq", "--no-trunc", "-f", "label=nexo.sandbox.id=#{@name}"]
      end

      # The ids of the containers carrying this sandbox's identity label, from the
      # output of #reconnect_argv. VERIFIED (Apple `container` 1.7.1): each entry
      # of the JSON list has an `id` and its labels under `configuration.labels`.
      def reconnect_ids(out)
        return out.strip.split("\n").reject(&:empty?) unless @runtime == :apple

        JSON.parse(out).select { |entry| entry.dig("configuration", "labels", "nexo.sandbox.id") == @name }
          .map { |entry| entry["id"] }
      end

      # Runs `cmd` inside the started container and returns the
      # `{ stdout:, stderr:, status: }` shape (integer exit code) of Local#shell.
      # Raises `Timeout::Error` after `timeout` seconds, with the command stopped
      # on both sides (see #capture!).
      def exec!(*cmd, timeout: 30)
        capture!(cmd, timeout: timeout)
      end

      # As #exec!, but feeds `data` to the command on stdin (used by `write` so
      # file contents never enter the argv). `-i` keeps stdin open.
      def exec_stdin!(data, *cmd, timeout: 30)
        capture!(cmd, timeout: timeout, stdin_data: data)
      end

      # Runs one `exec` through Subprocess, which kills the runtime's client
      # process when the time is up. That alone leaves the command running
      # INSIDE the container, so each exec carries a marker in its environment
      # and a timeout also kills every process in the container that has it.
      def capture!(cmd, timeout:, stdin_data: nil)
        ensure_started!
        marker = SecureRandom.hex(8)
        argv = exec_argv(*cmd, interactive: !stdin_data.nil?, marker: marker)
        out, err, status = Subprocess.capture(ENV.to_h, *argv, timeout: timeout, stdin_data: stdin_data)
        {stdout: out, stderr: err, status: status}
      rescue Timeout::Error
        kill_marked(marker)
        raise
      end

      # Kills every process in the container started by the exec carrying
      # `marker`. Best-effort and bounded: it must never hide the timeout.
      def kill_marked(marker)
        Subprocess.capture(ENV.to_h, *kill_argv(marker), timeout: 10)
      rescue
        nil
      end

      # The argv that kills the processes of one exec (pure, offline-assertable).
      # The marker is passed as `$1`, never interpolated into the script.
      def kill_argv(marker)
        script = "for p in /proc/[0-9]*; do " \
          'if tr "\0" "\n" < "$p/environ" 2>/dev/null | grep -qx "NEXO_EXEC=$1"; then ' \
          'kill -9 "${p#/proc/}" 2>/dev/null; fi; done; true'
        [@bin, "exec", @cid, "sh", "-c", script, "sh", marker]
      end

      # The `exec` argv (pure, offline-assertable). `interactive:` inserts `-i`;
      # `marker:` tags the command's environment so a timeout can find it.
      def exec_argv(*cmd, interactive: false, marker: nil)
        argv = [@bin, "exec"]
        argv << "-i" if interactive
        argv += ["-e", "NEXO_EXEC=#{marker}"] if marker
        argv += [@cid, *cmd]
        argv
      end

      # Local's path-escape guard, applied to the CONTAINER path: expand against
      # `cwd` and raise `SecurityError` if it escapes. Runs before any `exec`.
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
