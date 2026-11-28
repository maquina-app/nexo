# frozen_string_literal: true

module Nexo
  # A `RubyLLM::FileStore` over any Nexo sandbox, so `ruby_llm`'s own file tools
  # (`list_files`, `read_file`, `search_files`, `write_file`, `edit_file`) work on
  # the files an agent's sandbox holds — in memory, on the host, or in a
  # container. Agent#chat builds one per chat when the agent declares
  # `file_tools :core`.
  #
  # What the store adds over Nexo's own three file tools comes from `ruby_llm`:
  # editing part of a file, searching file contents, and a read-before-write
  # guard that compares content digests, so it works on every sandbox (Nexo's own
  # guard compares modification times and is skipped on Virtual).
  #
  # Every path goes through the sandbox, so the sandbox's own confinement still
  # applies: `RubyLLM::FileStore.path` refuses `..` before the store is asked, and
  # Sandboxes::Local raises `SecurityError` for a symlink that leaves `cwd`.
  #
  # Deleting goes through Sandbox#delete, for a sandbox that has one (0.17);
  # Agent attaches `delete_file` only then.
  #
  # VERIFIED (ruby_llm 2.2.3): a store implements `list`, `[]`, `read`, `write`
  # and `delete`; the tools also use the inherited `with_lock`, `read_digest`,
  # `record_read` and `text_with_digest`.
  class SandboxFileStore < ::RubyLLM::FileStore
    # Wraps `sandbox` (a Nexo::Sandbox).
    def initialize(sandbox)
      super()
      @sandbox = sandbox
    end

    # The files inside the folder `prefix`, or every file, sorted by path. Sizes
    # come from Sandbox#file_size; digests are left for the tools to compute when
    # they read a file, so a listing does not read every file.
    def list(prefix = nil)
      @sandbox.files.select { |path| ::RubyLLM::FileStore.inside?(path, prefix) }.sort.map do |path|
        stored(path, byte_size: @sandbox.file_size(path))
      end
    end

    # The StoredFile at `path`, or `nil` when there is none.
    def [](path)
      path = ::RubyLLM::FileStore.path(path)
      content = fetch(path) or return
      stored(path, byte_size: content.bytesize, content: content)
    end

    # The content of the file at `path`, as bytes.
    def read(path)
      path = ::RubyLLM::FileStore.path(path)
      fetch(path) or raise ::RubyLLM::FileNotFoundError, "No file at #{path}"
    end

    # Writes `content` to `path` through the sandbox and returns its StoredFile.
    def write(path, content, content_type: nil)
      path = ::RubyLLM::FileStore.path(path)
      content = ::RubyLLM::FileStore.bytes(content)
      with_lock { @sandbox.write(path, content) }
      stored(path, byte_size: content.bytesize, content: content, content_type: content_type)
    end

    # Deletes the file at `path` through the sandbox, for a sandbox that can
    # (see Sandbox#deletes?), and returns its StoredFile, or `nil` when there
    # was none.
    def delete(path)
      path = ::RubyLLM::FileStore.path(path)
      raise NotImplementedError, "this sandbox cannot delete files" unless @sandbox.deletes?

      file = self[path] or return
      with_lock { @sandbox.delete(path) }
      file
    rescue Errno::ENOENT, Errno::EISDIR
      nil
    end

    private

    # The bytes at `path`, or `nil` when the sandbox has no such file.
    def fetch(path)
      @sandbox.read(path).to_s.b
    rescue Errno::ENOENT, Errno::EISDIR, IOError
      nil
    end

    # Builds the StoredFile for `path`. With the content at hand its digest and
    # sniffed type are exact; a listing entry gets its type from the file name.
    def stored(path, byte_size:, content: nil, content_type: nil)
      ::RubyLLM::StoredFile.new(
        path: path,
        byte_size: byte_size,
        content_type: content_type || ::RubyLLM::FileStore.content_type_for(path, content || ""),
        digest: content && ::RubyLLM::FileStore.digest(content)
      )
    end
  end
end
