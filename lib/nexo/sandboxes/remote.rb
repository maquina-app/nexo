# frozen_string_literal: true

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

      # Lists paths matching +pattern+ by running +ls+ remotely and splitting the
      # client's stdout into an array of lines.
      def glob(pattern)
        @client.exec("ls #{pattern}")[:stdout].to_s.split("\n")
      end

      # Releases the remote session via the client.
      def close
        @client.close
      end
    end
  end
end
