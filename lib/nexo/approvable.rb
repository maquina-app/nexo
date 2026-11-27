# frozen_string_literal: true

module Nexo
  # What makes a tool pause for a person under an `:approve` gate, through
  # `ruby_llm`'s own approval mechanism (0.16).
  #
  # Before a tool runs, `ruby_llm` asks it `requires_approval?(tool_call)` and,
  # when that is true, reads the decision from its `approval_resolver`. A tool
  # that includes this module answers both from the agent's Permissions: whether
  # this call needs a decision, and the one recorded for it (see
  # Permissions#decision_for). With no decision recorded `ruby_llm` pauses the
  # call and the loop raises Nexo::ApprovalRequired; a declined call gets
  # `ruby_llm`'s refusal as its result; an approved one runs.
  #
  # Decisions are keyed by what the call does (Permissions::approval_key), not by
  # the tool call's id, so one recorded on a run still matches after a resume
  # asks the model again.
  #
  # The including class holds `@permissions` and defines `approval_subject`.
  # The gate inside the tool (Permissions#authorize!) is unchanged and still
  # refuses an undecided call that reaches it some other way.
  module Approvable
    # Whether `tool_call` must be decided by a person before it runs.
    def requires_approval?(tool_call = nil)
      return false unless tool_call

      @permissions.needs_approval?(*approval_subject(approval_arguments(tool_call)))
    end

    # Reads the recorded decision for a call: `true`, `false`, or `nil` while
    # nobody has decided.
    def approval_resolver
      ->(tool_call) { @permissions.decision_for(*approval_subject(approval_arguments(tool_call))) }
    end

    # The capability, detail and arguments a call is authorized and decided
    # under, as an Array — the same three the tool hands Permissions when it runs.
    def approval_subject(arguments)
      raise NotImplementedError, "#{self.class} must define approval_subject(arguments)"
    end

    private

    # A tool call's arguments with Symbol keys.
    def approval_arguments(tool_call)
      (tool_call.arguments || {}).to_h.transform_keys(&:to_sym)
    end
  end
end
