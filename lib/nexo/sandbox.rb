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
  end
end
