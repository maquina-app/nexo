# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module Nexo
  module MCP
    # Keeps the OAuth credentials of MCP servers on disk, so a host outside Rails
    # — a CLI, a script, a daemon — stays authorized across restarts. `ruby_llm`
    # keeps them in memory by default and in an encrypted table under Rails; this
    # is the third option, in the same spirit as RunStore::Disk.
    #
    # ```ruby
    # RubyLLM.configure do |config|
    #   config.mcp_credential_store = Nexo::MCP::CredentialStore.new(dir: "~/.local/state/my-app/mcp")
    # end
    # ```
    #
    # It answers the store contract `ruby_llm` documents: `read(key)`,
    # `write(key, data, owner:)`, `delete(key)` and `synchronize(key)`.
    #
    # ⚠️ SECURITY: the files hold live access and refresh tokens, in plain JSON.
    # They are NOT encrypted. The directory is created `0700` and every file
    # `0600`, so they are readable by your user and nobody else — the same
    # protection an SSH key or a `gh` token has, and no more. Do not point this at
    # a shared or synced directory, and prefer the encrypted Rails table when
    # ActiveRecord is available. File names are a digest of the key, so the
    # directory listing reveals neither owners nor servers.
    class CredentialStore
      # The directory the credentials live in (expanded).
      attr_reader :dir

      # Roots the store at `dir`, creating it `0700` if needed.
      def initialize(dir:)
        @dir = File.expand_path(dir)
        FileUtils.mkdir_p(@dir, mode: 0o700)
      end

      # The credentials stored under `key` as a Hash, or `nil`. A file that is
      # missing or unreadable as JSON reads as `nil`: the server is then simply
      # not authorized, which is the safe answer.
      def read(key)
        JSON.parse(File.read(path(key)))
      rescue Errno::ENOENT, JSON::ParserError
        nil
      end

      # Stores `data` under `key`. Written to a temporary file and renamed, so a
      # reader never sees half a file and a crash never leaves one. `owner:` is
      # part of the contract and already part of the key.
      def write(key, data, **)
        target = path(key)
        temporary = "#{target}.#{Process.pid}.#{Thread.current.object_id}.tmp"
        File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(data)) }
        File.rename(temporary, target)
        data
      ensure
        File.delete(temporary) if temporary && File.exist?(temporary)
      end

      # Forgets the credentials stored under `key`.
      def delete(key)
        File.delete(path(key))
      rescue Errno::ENOENT
        nil
      end

      # Runs the block while no other process holds `key`, so two processes
      # sharing the directory never refresh the same token at once.
      def synchronize(key)
        File.open("#{path(key)}.lock", File::RDWR | File::CREAT, 0o600) do |lock|
          lock.flock(File::LOCK_EX)
          yield
        end
      end

      private

      # The file for `key`: a digest, so a key containing a URL is a safe name.
      def path(key)
        File.join(@dir, "#{Digest::SHA256.hexdigest(key.to_s)}.json")
      end
    end
  end
end
