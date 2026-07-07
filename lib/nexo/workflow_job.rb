# frozen_string_literal: true

# Rails-only. Mirrors lib/nexo/workflow_run.rb exactly: the whole body is guarded
# by defined?(::ActiveJob) (so requiring it in plain Ruby / a Rails app with no
# ActiveJob defines nothing), it is ignored by the Zeitwerk loader in lib/nexo.rb
# (no autoload registered), and it is required by an engine initializer once
# ActiveJob is present.
if defined?(::ActiveJob)
  module Nexo
    # Executes a queued {Workflow} run on the host's ActiveJob adapter (Spec 11 R1).
    # Subclasses ::ActiveJob::Base — the host-agnostic base — rather than the host's
    # ApplicationJob, so the job is self-contained. It carries ONLY the run id; the
    # payload lives on the run record (never passed through job args), so no secrets
    # travel through the queue.
    #
    # Reconstitutes the workflow class and calls {Workflow.execute}, which the sync
    # {Workflow.run} shares — so an async run reaches the same done/failed lifecycle,
    # event log, and status notifications. A crashed/retried run is not auto-resumed:
    # a retried job re-runs +#call+ from scratch (Nexo adds no retry_on).
    #
    # With a second +resume_input+ argument (Spec 13, from {Workflow.resume_later})
    # it dispatches the **durable resume** path instead: it re-enters {Workflow.resume}
    # (which re-finds the run, guards it is still +"suspended"+ so a race that already
    # resumed fails cleanly, and re-runs +#call+ from the top with the resume input).
    # With no resume argument it takes the original enqueue path, byte-for-byte
    # backward compatible.
    class WorkflowJob < ::ActiveJob::Base
      def perform(run_id, resume_input = nil)
        if resume_input.nil?
          run = Nexo::RunStore.default.find(run_id)
          klass = run.workflow_class.constantize
          klass.execute(run, payload: run.payload.transform_keys(&:to_sym))
        else
          Nexo::Workflow.resume(run_id, resume_input.transform_keys(&:to_sym))
        end
      end
    end
  end
end
