# frozen_string_literal: true

require "json"

module Nexo
  # Wraps any tool so every call is authorized through Nexo::Permissions before it
  # runs. A denied call returns `{ error: ... }` (recoverable) and never raises
  # into the loop — the same authorize → act → rescue-`Denied` → `{error:}` shape
  # as Nexo's own sandbox tools. Under an `:approve` gate the call pauses before it
  # gets here (see Approvable); Nexo::ApprovalRequired from the gate itself, for a
  # call that reached it undecided some other way, is not rescued.
  #
  # This is how a tool the host wrote gets the same gate as Nexo's own: declare it
  # with a capability (`tools ArchiveRun, capability: :write`) and Agent#chat wraps
  # it here. MCP::GatedTool is the same wrapper on the MCP axis.
  #
  # Everything except the execution method is delegated to the wrapped tool, so
  # the chat cannot tell the wrapper apart from the raw tool: it reports the same
  # `name`/`description`/`parameters_schema` and serializes identically.
  #
  # VERIFIED (ruby_llm 2.2.3): `Chat#with_tools` does not type-check — it registers
  # any object answering `qualified_name`/`namespace`/`name`/`deferred?` — and the
  # tool loop invokes `tool.call(**arguments, tool_call:)` with KEYWORDS. So a
  # delegating wrapper is accepted; `method_missing` forwards every reader the
  # chat and the provider renderers ask for.
  class GatedTool
    include Approvable

    # Wraps `tool` so every call is authorized for `capability` (one of the
    # Permissions capabilities, e.g. `:write`) through `permissions` first.
    #
    # `detail:` is an optional `->(arguments)` returning what the gate is told the
    # call acts on — a path, say. Without it, or when it returns `nil`, the detail
    # is the tool name and its arguments as JSON, so two different calls are never
    # mistaken for one when an approval is recorded.
    #
    # `prepare:` is an optional `->(arguments)` returning the arguments the gate
    # and the tool should see instead — used to normalize a path, for instance.
    def initialize(tool:, permissions:, capability:, detail: nil, prepare: nil)
      @tool = tool
      @permissions = permissions
      @capability = capability
      @detail = detail
      @prepare = prepare
    end

    # Authorizes the call, then delegates to the wrapped tool. A denial is
    # returned as `{ error: ... }` so the model can recover.
    #
    # Arguments arrive as keywords from the chat loop. A single positional Hash
    # is accepted too, for direct callers. `tool_call:` is the chat's own
    # bookkeeping, not a tool argument, so the gate never sees it.
    def call(args = nil, **kwargs)
      arguments = (args || {}).to_h.merge(kwargs).transform_keys(&:to_sym)
      authorize!(arguments.except(:tool_call))
      arguments = @prepare.call(arguments) if @prepare
      @tool.call(**arguments)
    rescue Nexo::Permissions::Denied => e
      {error: e.message}
    end

    # The wrapped tool's name.
    def name = @tool.name

    # Routes `#execute` through the same gate, so the wrapper is safe whichever
    # entry point a caller uses.
    def execute(*args, **kwargs)
      call(args.first, **kwargs)
    end

    # Forward description/parameters_schema/to_h/etc. to the wrapped tool so the
    # chat serializes it exactly like the raw tool — but never `execute` (see
    # above).
    def respond_to_missing?(method_name, include_private = false)
      return true if method_name == :execute

      @tool.respond_to?(method_name, include_private) || super
    end

    # Delegates any unknown method to the wrapped tool (description,
    # parameters_schema, to_h, ...), so the wrapper serializes identically. `execute`
    # is handled explicitly above and never falls through here.
    def method_missing(method_name, *args, **kwargs, &block)
      if @tool.respond_to?(method_name)
        @tool.public_send(method_name, *args, **kwargs, &block)
      else
        super
      end
    end

    # What a call is authorized and decided under: the capability and the detail
    # handed to `ask_when`/`on_ask` and recorded with an approval — the `detail:`
    # callable's answer, or the tool name and its arguments, so a human can tell
    # one call from another.
    def approval_subject(arguments)
      arguments = @prepare.call(arguments) if @prepare
      [@capability, @detail&.call(arguments) || "#{name} #{JSON.generate(arguments)}"]
    end

    private

    # The gate.
    def authorize!(arguments)
      @permissions.authorize!(*approval_subject(arguments))
    end
  end
end
