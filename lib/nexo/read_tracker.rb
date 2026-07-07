# frozen_string_literal: true

module Nexo
  # A tiny per-chat memory of which files an agent has read and at what
  # last-modified time, so {Tools::WriteFile} can refuse to overwrite a file the
  # model never read — or one that changed underneath it — within a session.
  #
  # Built once per chat in {Agent#chat} and threaded into both {Tools::ReadFile}
  # (which records) and {Tools::WriteFile} (which enforces). Scope is clobber
  # safety *within a session* only: no versioning, no locking, no VCS semantics.
  class ReadTracker
    def initialize
      @mtimes = {}
    end

    # Records that +path+ was read when it had modification time +mtime+.
    def record(path, mtime)
      @mtimes[path] = mtime
    end

    # Whether +path+ has been read in this session.
    def read?(path)
      @mtimes.key?(path)
    end

    # The mtime recorded when +path+ was read, or +nil+ if it was never read.
    def recorded_mtime(path)
      @mtimes[path]
    end
  end
end
