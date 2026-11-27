# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "openssl"
require "securerandom"

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
    # ⚠️ SECURITY: the files hold live access and refresh tokens. The directory
    # is created `0700` and every file `0600`, so they are readable by your user
    # and nobody else. File names are a digest of the key, so the directory
    # listing reveals neither owners nor servers.
    #
    # Without a `key:` the contents are plain JSON — the protection an SSH key
    # or a `gh` token has, and no more: fine for a personal CLI, wrong for a
    # shared or synced directory or a backed-up server. Pass a `key:` and every
    # file is encrypted with AES-256-GCM (0.16):
    #
    # ```ruby
    # Nexo::MCP::CredentialStore.new(dir: "/var/lib/my-app/mcp", key: ENV.fetch("MCP_STORE_KEY"))
    # ```
    #
    # The key is 32 random bytes, given raw or as 64 hex characters — make one
    # with ::generate_key and keep it OUT of the directory (an environment
    # variable, a keychain, a secrets manager). A file that does not decrypt —
    # wrong key, tampering, or an encrypted file read with no key — reads as
    # `nil`, so the server is simply not authorized. Plain files written before
    # a key was set are still read, and are encrypted the next time they are
    # written.
    class CredentialStore
      # The cipher every encrypted file uses.
      CIPHER = "aes-256-gcm"

      # A new random key for `key:`, as 64 hex characters.
      def self.generate_key = SecureRandom.hex(32)

      # The directory the credentials live in (expanded).
      attr_reader :dir

      # Roots the store at `dir`, creating it `0700` if needed. With `key:` the
      # files are encrypted. Raises ConfigurationError for a key that is not 32
      # bytes (or 64 hex characters).
      def initialize(dir:, key: nil)
        @key = cipher_key(key)
        @dir = File.expand_path(dir)
        FileUtils.mkdir_p(@dir, mode: 0o700)
      end

      # Whether the files are encrypted.
      def encrypted? = !@key.nil?

      # The credentials stored under `key` as a Hash, or `nil`. A file that is
      # missing, unreadable as JSON, or that does not decrypt reads as `nil`: the
      # server is then simply not authorized, which is the safe answer.
      def read(key)
        stored = JSON.parse(File.read(path(key)))
        sealed?(stored) ? unseal(key, stored) : stored
      rescue Errno::ENOENT, JSON::ParserError, OpenSSL::Cipher::CipherError, ArgumentError
        nil
      end

      # Stores `data` under `key`. Written to a temporary file and renamed, so a
      # reader never sees half a file and a crash never leaves one. `owner:` is
      # part of the contract and already part of the key.
      def write(key, data, **)
        target = path(key)
        temporary = "#{target}.#{Process.pid}.#{Thread.current.object_id}.tmp"
        File.open(temporary, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(JSON.generate(@key ? seal(key, data) : data)) }
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

      # The 32-byte key from what the host passed: raw bytes or 64 hex characters.
      def cipher_key(key)
        return if key.nil?

        bytes = key.to_s
        bytes = [bytes].pack("H*") if bytes.match?(/\A\h{64}\z/)
        return bytes.b if bytes.bytesize == 32

        raise Nexo::ConfigurationError,
          "the credential store key must be 32 bytes, or 64 hex characters " \
          "(make one with Nexo::MCP::CredentialStore.generate_key)"
      end

      # Whether a parsed file is an encrypted envelope rather than credentials.
      def sealed?(stored)
        stored.is_a?(Hash) && stored["nexo_sealed"] == 1
      end

      # Encrypts `data` for `key`. The key name is authenticated with the
      # ciphertext, so a file copied over another owner's does not decrypt.
      def seal(key, data)
        cipher = OpenSSL::Cipher.new(CIPHER).encrypt
        cipher.key = @key
        iv = cipher.random_iv
        cipher.auth_data = key.to_s
        sealed = cipher.update(JSON.generate(data)) + cipher.final
        {"nexo_sealed" => 1, "iv" => [iv].pack("m0"),
         "tag" => [cipher.auth_tag].pack("m0"), "data" => [sealed].pack("m0")}
      end

      # Decrypts an envelope. With no key configured there is nothing to decrypt
      # with, which reads as "not authorized".
      def unseal(key, stored)
        return unless @key

        cipher = OpenSSL::Cipher.new(CIPHER).decrypt
        cipher.key = @key
        cipher.iv = stored.fetch("iv").unpack1("m0")
        cipher.auth_tag = stored.fetch("tag").unpack1("m0")
        cipher.auth_data = key.to_s
        JSON.parse(cipher.update(stored.fetch("data").unpack1("m0")) + cipher.final)
      rescue KeyError
        nil
      end

      # The file for `key`: a digest, so a key containing a URL is a safe name.
      def path(key)
        File.join(@dir, "#{Digest::SHA256.hexdigest(key.to_s)}.json")
      end
    end
  end
end
