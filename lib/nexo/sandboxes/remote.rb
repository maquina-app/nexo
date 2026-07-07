# frozen_string_literal: true

require "shellwords"

module Nexo
  module Sandboxes
    # A provider-agnostic remote sandbox: it runs an agent's tools inside some
    # remote container (E2B / Daytona / Modal / Docker / your own) by delegating
    # the four-method Sandbox contract to an injected +client+.
    #
    # The client is any object responding to +read+/+write+/+exec+/+close+. That
    # four-method contract is the entire integration surface — +Remote+ contains
    # ZERO vendor code, so switching providers is swapping the injected object,
    # not changing Nexo. Adapt a vendor client to the contract with a tiny shim
    # (see the README's shim-pattern example).
    #
    #   sandbox = Nexo::Sandboxes::Remote.new(client: my_container_client)
    #
    # The client's +exec+ is expected to return the same shape the Sandbox
    # +shell+ contract documents — +{ stdout:, stderr:, status: }+ — so +#shell+
    # passes it straight through and +#glob+ can read +[:stdout]+. Adapting a
    # vendor client to that shape is the shim's job (see the README example).
    #
    # Escalating to +:remote+ is always an explicit choice in user code; the
    # default sandbox stays +:virtual+.
    class Remote < Sandbox
      # Stores any object responding to +read+/+write+/+exec+/+close+.
      def initialize(client:)
        @client = client
      end

      # Reads +path+ via the client.
      def read(path)
        @client.read(path)
      end

      # Writes +content+ to +path+ via the client.
      def write(path, content)
        @client.write(path, content)
      end

      # Runs +command+ via the client's +exec+ and returns its result. The client
      # is expected to honor +timeout:+ (seconds) the way the rest of the contract
      # honors the Sandbox shape.
      def shell(command, timeout: 30)
        @client.exec(command, timeout: timeout)
      end

      # Supports all four capabilities: the injected client runs a real remote
      # process, so — unlike Virtual — an agent on a Remote sandbox gets the Shell
      # tool attached (Agent#chat gates Shell on +supports?(:shell)+).
      def supports?(cap)
        %i[read write shell glob].include?(cap)
      end

      # Lists paths matching +pattern+ by expanding it remotely and splitting the
      # client's stdout into an array of lines.
      #
      # The pattern is handed to an inner shell as a positional parameter (+$1+),
      # so +for f in $1+ performs the remote glob expansion, while Shellwords
      # keeps both the script and the pattern single opaque tokens to the outer
      # shell — a model-supplied pattern (e.g. +"x; rm -rf ~"+) can't inject
      # commands (assumes a POSIX +sh+ on the remote, which the shell contract
      # already implies).
      def glob(pattern)
        script = 'for f in $1; do [ -e "$f" ] && echo "$f"; done'
        command = "sh -c #{Shellwords.escape(script)} sh #{Shellwords.escape(pattern)}"
        @client.exec(command)[:stdout].to_s.split("\n")
      end

      # Releases the remote session via the client.
      def close
        @client.close
      end
    end
  end
end
