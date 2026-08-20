# frozen_string_literal: true

module Nexo
  # The execution-environment seam. A sandbox is where an agent's tools actually
  # touch files and run commands; swapping the sandbox swaps the whole execution
  # context (in-memory, host, or — later — remote) by constructor injection.
  #
  # Concrete sandboxes implement the four-method contract below. The base class
  # raises +NotImplementedError+ for each so an incomplete subclass fails loudly.
  #
  # See Sandboxes::Virtual (default, zero host access) and Sandboxes::Local
  # (host filesystem + shell, guarded).
  class Sandbox
    # Returns the contents of +path+ as a String.
    def read(path)
      raise NotImplementedError
    end

    # Writes +content+ to +path+.
    def write(path, content)
      raise NotImplementedError
    end

    # Runs +command+ and returns +{ stdout:, stderr:, status: }+ (status is the
    # integer exit code). +timeout+ is in seconds.
    def shell(command, timeout: 30)
      raise NotImplementedError
    end

    # Returns the paths matching the glob +pattern+.
    def glob(pattern)
      raise NotImplementedError
    end

    # Releases any resources the sandbox holds. No-op by default.
    def close
      nil
    end

    # A short, plain-text description of the execution environment (cwd, host
    # access, network) for the agent to inject into the system prompt. Base
    # returns +nil+ — inject nothing. Real-filesystem sandboxes (Local,
    # Container) override this so a weak tool-caller knows where it runs.
    def instructions
      nil
    end

    # Whether the sandbox supports +capability+ (one of +:read+, +:write+,
    # +:glob+, +:shell+). The base supports everything but +:shell+ (an
    # in-memory sandbox has no process to run a command in), so an agent only
    # attaches the +Shell+ tool when the sandbox reports it. Real-process
    # sandboxes (Local, Container) override to add +:shell+.
    def supports?(capability)
      capability != :shell
    end

    # The last-modified time of +path+, used by the read-before-write + stale
    # guard for real-filesystem sandboxes. Base returns +nil+ (no external
    # mutation to guard against, e.g. Virtual), which disables the guard.
    def mtime(path)
      nil
    end

    # Commands the default #environment probe looks for. Deliberately short —
    # each entry costs a +command -v+ plus one +--version+ when found — and
    # extensible per call for anything else a skill's script might need.
    PROBE_COMMANDS = %w[ruby python3 node sh].freeze

    # The shape #environment always answers with, built fresh on every call.
    # Deliberately a method and not a frozen constant: the +:commands+ Hash is
    # mutated while parsing, and +CONST.dup+ is shallow — sharing one inner Hash
    # let every probe accumulate into the constant, so a sandbox with no shell
    # answered with the previous sandbox's findings. +:error+ is nil on a
    # successful probe and carries the reason when one could not be run.
    def self.empty_environment
      {commands: {}, locale: nil, error: nil}
    end

    # One POSIX +sh+ script, no interpreter required on the far side, so the probe
    # works on a busybox image. +command -v+ locates each command and a single
    # +--version+ reports it; the format placeholder is filled by #environment.
    PROBE_SCRIPT = <<~SH
      printf 'locale=%%s\\n' "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
      for c in %<commands>s; do
        p=$(command -v "$c" 2>/dev/null) || continue
        v=$("$c" --version 2>/dev/null | head -1)
        printf 'cmd=%%s\\t%%s\\t%%s\\n' "$c" "$p" "$v"
      done
    SH

    # What this execution environment actually provides, as data:
    #
    #   sandbox.environment
    #   # => { commands: { "ruby" => { path: "/usr/local/bin/ruby", version: "4.0.0" } },
    #   #      locale: "C.UTF-8" }
    #
    # #instructions describes the environment *for the model*; this is the same
    # question answered *for code*, so a caller can check before staging a skill's
    # script rather than discovering the answer as a stack trace several turns in.
    # A container typically has no locale at all, under which Ruby's default
    # external encoding is US-ASCII and a bare File.read on a UTF-8 file raises —
    # and an image can carry a full Ruby toolchain and still report no locale, so
    # the two are reported as independent axes.
    #
    # Deliberately coarse: commands on +PATH+ and the locale, never packages. Gems,
    # wheels and npm modules belong to whoever builds the image, and modelling them
    # here would be a cross-language dependency resolver competing with the manifest
    # every ecosystem already has.
    #
    # Costs one #shell round trip and is memoized for the sandbox's lifetime (0.14s
    # on +:local+, 0.25–0.48s on a container, measured). A sandbox with no shell
    # A sandbox with no shell (Virtual) reports empty. A probe that fails for any
    # other reason — the container would not start, the client is unreachable —
    # also reports empty, but carries the reason under +:error+: this is
    # diagnostics and must never be the reason a run dies, yet "I probed and found
    # nothing" and "I could not probe" are different answers and a caller building
    # an error message needs to tell them apart.
    def environment(commands: PROBE_COMMANDS)
      @environment ||= {}
      @environment[commands] ||= probe_environment(commands)
    end

    private

    # Runs the probe and parses its output. Rescues everything: see #environment.
    def probe_environment(commands)
      return Sandbox.empty_environment.merge(error: "sandbox has no shell") unless supports?(:shell)

      out = shell(format(PROBE_SCRIPT, commands: Array(commands).join(" ")))
      parse_environment(out[:stdout].to_s)
    rescue StandardError, NotImplementedError => e
      Sandbox.empty_environment.merge(error: "#{e.class}: #{salient_line(e.message)}")
    end

    # The most useful single line of a multi-line runtime failure. Neither the
    # first line nor a blind truncation works: a container runtime prints a
    # progress banner first ("[1/6] Fetching image", "container start failed")
    # and puts the actual cause last ("The volume is read only"). Prefer the last
    # line that announces an error, else the last non-empty line.
    def salient_line(message)
      lines = message.to_s.lines.map(&:strip).reject(&:empty?)
      # Written as a plain scan on purpose. The idiomatic spellings deadlock the
      # linter — Style/ReverseFind rewrites `reverse.find` to Enumerable#rfind,
      # which does not exist on the Ruby 3.3 floor this gem supports, and
      # Performance/Detect rewrites `select.last` straight back to `reverse.find`.
      line = nil
      lines.each { |l| line = l if l.match?(/error|fail|cause/i) }
      line ||= lines.last
      line.to_s[0, 300]
    end

    # Turns the probe's line protocol into the #environment Hash. An empty locale
    # line means "unset", which is the interesting case, so it maps to +nil+ rather
    # than an empty String.
    def parse_environment(stdout)
      env = Sandbox.empty_environment
      stdout.each_line do |line|
        case line.chomp
        when /\Alocale=(.*)\z/
          env[:locale] = $1.empty? ? nil : $1
        when /\Acmd=([^\t]*)\t([^\t]*)\t(.*)\z/
          # A command that prints no version (busybox sh) still counts as present;
          # an unreadable version is not evidence of a wrong one.
          env[:commands][$1] = {path: $2, version: $3[/(\d+(?:\.\d+)+)/]}
        end
      end
      env
    end
  end
end
