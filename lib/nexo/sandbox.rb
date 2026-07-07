# frozen_string_literal: true

module Nexo
  # The execution-environment seam. A sandbox is where an agent's tools actually
  # touch files and run commands; swapping the sandbox swaps the whole execution
  # context (in-memory, host, or — later — remote) by constructor injection.
  #
  # Concrete sandboxes implement the four-method contract below. The base class
  # raises +NotImplementedError+ for each so an incomplete subclass fails loudly.
  #
  # See {Sandboxes::Virtual} (default, zero host access) and {Sandboxes::Local}
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
  end
end
