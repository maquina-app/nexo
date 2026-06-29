# frozen_string_literal: true

# Pure-Ruby workflow used by the dummy app to verify the Rails persistence path
# end to end (generator → migrate → run). No Agent/model involved — Spec 2 keeps
# the example provider-neutral.
class SummarizeWorkflowStub < Nexo::Workflow
  def call(payload)
    emit(:started, length: payload[:text].to_s.length)
    summary = payload[:text].to_s.slice(0, 280)
    emit(:summarized, length: summary.to_s.length)
    {summary: summary}
  end
end
