# frozen_string_literal: true

# Rails-only persistence model for {Nexo::Workflow} runs. The body subclasses
# ::ActiveRecord::Base, so it is loaded only when ActiveRecord is present (the
# engine requires this file once AR is available). The plain-Ruby path never
# reaches here — lib/nexo.rb ignores this file in the Zeitwerk loader, so no
# autoload is registered and defined?(Nexo::WorkflowRun) stays false offline.
if defined?(::ActiveRecord::Base)
  module Nexo
    # The +nexo_workflow_runs+ record: a run's id, workflow class, status,
    # payload, result, error, and ordered event log. Mirrors the shape of the
    # in-memory store's Run struct so a single {Workflow} drives either backend.
    class WorkflowRun < ::ActiveRecord::Base
      self.table_name = "nexo_workflow_runs"

      # The primary key is a UUID string assigned through the shared
      # {Nexo.generate_run_id} helper, keeping id shape identical across stores.
      before_create :assign_run_id

      # No presence validations on +result+ or +events+: both are empty until
      # the run finishes.

      # Appends an event to the ordered log. Reassigns the array (rather than
      # mutating in place) so ActiveRecord tracks the json column as dirty.
      def push_event(ev)
        self.events = (events || []) + [ev]
      end

      # Persists the event log without bumping +updated_at+ — events accrue
      # incrementally during a run and shouldn't each count as a full touch.
      def save_events!
        save!(touch: false)
      end

      # Appends an artifact to the ordered index (Spec 7). Reassigns the array
      # (rather than mutating in place) so ActiveRecord tracks the json column as
      # dirty — mirrors {#push_event} exactly.
      def push_artifact(a)
        self.artifacts = (artifacts || []) + [a]
      end

      # Persists the artifact index without bumping +updated_at+, mirroring
      # {#save_events!}.
      def save_artifacts!
        save!(touch: false)
      end

      private

      def assign_run_id
        self.id = Nexo.generate_run_id if id.blank?
      end
    end
  end
end
