# frozen_string_literal: true

require "digest"
require "json"

module Nexo
  # The authorization gate for a sandbox's capabilities. Each tool asks
  # `authorize!` before it touches the sandbox, so gating is provider-independent
  # and does not rely on any framework callback.
  #
  # Modes:
  # * `:auto`      — allow everything.
  # * `:read_only` — allow `:read`/`:glob`, deny `:write`/`:shell`/`:fetch`/`:search` (the default).
  # * `:ask`       — defer to `on_ask`; a truthy return allows, anything else denies.
  # * `:approve`   — durable, cross-process sibling of `:ask`: a call with no
  #   recorded decision pauses (see Approvable) and Workflow#run_agent suspends
  #   the run; a call approved in `decisions` runs, one declined there is
  #   refused. Decisions are per call: approving one write does not approve the
  #   next.
  #
  # Capabilities are `:read`, `:glob`, `:write`, `:shell`, `:fetch`, `:search`.
  # Anything listed in `allow:` is permitted regardless of mode.
  class Permissions
    # The recognized permission modes: `:auto`, `:read_only`, `:ask`, `:approve`.
    MODES = %i[auto read_only ask approve].freeze

    # The capabilities `:read_only` refuses. Named once so #authorize! and
    # #never_allows? cannot drift apart: the whole value of the predicate is that
    # it reports what the gate will actually do, so both must read the same list.
    PRIVILEGED = %i[write shell fetch search].freeze

    # Raised when a capability is not authorized. Tools rescue this and return
    # `{ error: ... }` so the agent loop continues.
    class Denied < StandardError; end

    # The configured Nexo permission mode (one of MODES).
    attr_reader :mode

    # The per-call approval decisions under `:approve` (0.14): a Hash of
    # ::approval_key → `true`/`false`, or `nil` when the gate was built without
    # one. A call whose key is absent is undecided and suspends. Ignored by every
    # other mode.
    attr_reader :decisions

    # The key one gated call is decided under: the capability and its detail (a
    # path, a command, a URL), plus a digest of the arguments when there are any
    # (MCP calls). Two calls share a key only when they are the same call, which
    # is what lets a resumed run recognize the call that was approved and still
    # ask about a different one. Keys and nested argument keys are normalized to
    # Strings, so a decision survives the JSON round trip of a run store.
    def self.approval_key(capability, detail, args = nil)
      key = "#{capability}:#{detail}"
      return key if args.nil? || (args.respond_to?(:empty?) && args.empty?)

      "#{key}:#{Digest::SHA256.hexdigest(JSON.generate(canonical(args)))[0, 16]}"
    end

    # `value` with Hash keys stringified and sorted, recursively, so equal
    # arguments always serialize to the same JSON.
    def self.canonical(value)
      case value
      when Hash then value.map { |k, v| [k.to_s, canonical(v)] }.sort_by(&:first).to_h
      when Array then value.map { |v| canonical(v) }
      else value
      end
    end
    private_class_method :canonical

    # `ask_when:` is an optional `->(capability, detail)` predicate that scopes
    # *which* actions actually prompt under `:ask` (and, unchanged, under
    # `:approve`): when it returns falsey the action is auto-allowed without
    # calling `on_ask` / requiring a decision; truthy (or when unset) falls
    # through to `on_ask` / the approval gate exactly as before. It only ever
    # *narrows* what is auto-allowed from the "ask/approve for everything"
    # baseline — it never widens authority. Applies to #authorize! only, not
    # #authorize_mcp!.
    #
    # `decisions:` (default `nil`) seeds the per-call `:approve` decisions (see
    # #decisions).
    def initialize(mode: :read_only, allow: %i[read glob], mcp_allow: [], on_ask: nil, ask_when: nil,
      decisions: nil)
      raise ArgumentError, "unknown mode #{mode}" unless MODES.include?(mode)

      @mode = mode
      @allow = allow
      @mcp_allow = mcp_allow.map(&:to_s)
      @on_ask = on_ask
      @ask_when = ask_when
      @decisions = decisions&.transform_keys(&:to_s)
    end

    # Returns a copy of this gate carrying the per-call `decisions` (see
    # #decisions), leaving the receiver untouched. Used to thread a run's recorded
    # approvals into a user-supplied, class-level `:approve` `Permissions`.
    def with_decisions(decisions)
      dup.tap { |copy| copy.instance_variable_set(:@decisions, decisions&.transform_keys(&:to_s)) }
    end

    # Authorizes `capability` (with optional `detail` passed to an `:ask` hook).
    # Returns `true` when allowed; raises Denied otherwise.
    def authorize!(capability, detail = nil)
      return true if @allow.include?(capability)

      case @mode
      when :auto
        true
      when :read_only
        raise Denied, "#{capability} denied in read_only mode" if PRIVILEGED.include?(capability)

        true
      when :ask
        # Scoped-ask: when ask_when says this action doesn't need a prompt,
        # auto-allow without calling on_ask. Unset ask_when = ask for everything.
        return true if @ask_when && !@ask_when.call(capability, detail)

        unless @on_ask&.call(capability, detail)
          raise Denied, "#{capability} (#{detail}) denied by user"
        end
        true
      when :approve
        # Durable approval (Spec 16). Scoped-approve: when ask_when says this
        # action doesn't need approval, auto-allow without a decision. Unset
        # ask_when = approve for everything.
        return true if @ask_when && !@ask_when.call(capability, detail)

        # Undecided ⇒ pause the run for a human (Branch A): the signal propagates
        # out of the tool loop; run_agent turns it into a suspend. Declined ⇒
        # never auto-allow; the tool rescues Denied into {error:} and the model
        # adapts.
        case decision_for(capability, detail)
        when nil then raise Nexo::ApprovalRequired.new(capability, detail)
        when true then true
        else raise Denied, "#{capability} (#{detail}) not approved"
        end
      end
    end

    # Whether `capability` can NEVER be authorized by this gate, for any call.
    #
    # True only under `:read_only`, for a PRIVILEGED capability absent from
    # `allow:` — that is the one case knowable ahead of time. Every other mode
    # decides per call and must be reported as *possible*: `:auto` allows, `:ask`
    # consults its hook, and `:approve` has to reach the gate so it can raise
    # ApprovalRequired and suspend the run.
    #
    # Agent#chat uses this to skip ATTACHING a tool the model could never
    # successfully call, so a guaranteed failure stops occupying the tool schema
    # on every turn. That makes this a cost and description-accuracy measure, not
    # a security boundary: #authorize! remains the gate and still denies at call
    # time whether or not the tool was advertised.
    def never_allows?(capability)
      return false if @allow.include?(capability)

      @mode == :read_only && PRIVILEGED.include?(capability)
    end

    # Whether the MCP tool `tool_name` can NEVER be authorized by this gate. The
    # MCP sibling of #never_allows?, true only under `:read_only` for a name
    # absent from `mcp_allow`. Agent uses it to leave such a tool out of the
    # schema; #authorize_mcp! remains the gate.
    def never_allows_mcp?(tool_name)
      @mode == :read_only && !@mcp_allow.include?(tool_name.to_s)
    end

    # Authorizes an MCP tool *call* by name. A deliberate sibling of #authorize!
    # on a separate capability axis: an MCP tool runs inside the MCP server,
    # outside the sandbox, so this gates the authority to *invoke* it — a different
    # guarantee than sandbox capability. Fails closed under `:read_only` (nothing
    # allowed unless the exact `tool_name` is listed in `mcp_allow`).
    #
    # * `:auto`      — allow every MCP tool.
    # * `:read_only` — allow only names in `mcp_allow` (default `[]` ⇒ deny all).
    # * `:ask`       — defer to `on_ask` with `(:mcp, {tool:, args:})`; a truthy
    #   return allows, anything else denies.
    # * `:approve`   — durable sibling of `:ask` on the MCP axis: names in
    #   `mcp_allow` are pre-approved, anything else needs a decision — undecided
    #   raises Nexo::ApprovalRequired (→ Workflow#run_agent suspends), `approved`
    #   allows, `approved: false` Denies.
    #
    # Returns `true` when allowed; raises Denied otherwise. The `else` is a
    # fail-closed backstop: a future mode that forgets to extend this gate denies
    # by default rather than silently allowing (the bug this replaced).
    def authorize_mcp!(tool_name, args = {})
      name = tool_name.to_s

      case @mode
      when :auto
        true
      when :read_only
        return true if @mcp_allow.include?(name)

        raise Denied, "mcp tool #{name} denied in read_only mode (not in mcp_allow)"
      when :ask
        unless @on_ask&.call(:mcp, {tool: name, args: args})
          raise Denied, "mcp tool #{name} denied by user"
        end
        true
      when :approve
        # Pre-approved read tools pass; everything else routes through the same
        # decision gate as #authorize!'s :approve branch.
        return true if @mcp_allow.include?(name)

        case decision_for(:mcp, name, args)
        when nil then raise Nexo::ApprovalRequired.new(:mcp, name, args)
        when true then true
        else raise Denied, "mcp tool #{name} not approved"
        end
      else
        raise Denied, "mcp tool #{name} denied (unhandled mode #{@mode})"
      end
    end

    # Whether one call needs a person's decision before it runs: only under
    # `:approve`, and only for what the gate does not already allow — a
    # capability in `allow:`, an MCP tool in `mcp_allow`, or a call `ask_when`
    # waves through needs none. `capability` is `:mcp` for an MCP tool, with its
    # name as `detail`. Approvable asks this before the call runs.
    def needs_approval?(capability, detail = nil, _args = nil)
      return false unless @mode == :approve
      return !@mcp_allow.include?(detail.to_s) if capability == :mcp
      return false if @allow.include?(capability)

      @ask_when.nil? || !!@ask_when.call(capability, detail)
    end

    # The recorded answer for one gated call under `:approve`: `true`, `false`,
    # or `nil` when nobody has decided it (see #decisions).
    def decision_for(capability, detail = nil, args = nil)
      @decisions && @decisions[self.class.approval_key(capability, detail, args)]
    end
  end
end
