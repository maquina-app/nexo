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

      # The status vocabulary a run moves through. The sync path is
      # pending → running → done/failed; run_later adds "queued" (enqueued, not yet
      # picked up); reconcile_interrupted! rewrites orphaned "running" runs to
      # "interrupted"; suspend! adds "suspended" (paused, awaiting resume — Spec 13,
      # NOT a failure). There is no distinct "resumed" status: resume re-enters
      # execute, transitioning running → done (or suspended again). Documentation
      # only — status is a plain string column.
      STATUSES = %w[pending queued running done failed interrupted suspended].freeze

      # Status scopes for a host UI (Spec 11 R3) — Nexo dictates no controllers or
      # views, only these query helpers.
      scope :queued, -> { where(status: "queued") }
      scope :running, -> { where(status: "running") }
      scope :finished, -> { where(status: %w[done failed]) }

      # Paused runs awaiting external input (Spec 13) — a host UI lists these to
      # surface a "needs approval" / "resume" affordance.
      scope :suspended, -> { where(status: "suspended") }

      # The primary key is a UUID string assigned through the shared
      # {Nexo.generate_run_id} helper, keeping id shape identical across stores.
      before_create :assign_run_id

      # Status predicates for a host UI (Spec 11 R3).
      def done? = status == "done"

      def failed? = status == "failed"

      def running? = status == "running"

      def queued? = status == "queued"

      # True while the run is paused awaiting external input (Spec 13).
      def suspended? = status == "suspended"

      # The reason recorded when the run was suspended (Spec 13), or nil when the
      # run was never suspended. Reads the reserved "__suspend__" state entry,
      # tolerating a nil state (a run predating the state column).
      def suspend_reason
        state&.dig("__suspend__", "reason")
      end

      # The stored result of a completed +checkpoint(name)+ (Spec 13), or nil when
      # that checkpoint has not run yet. Tolerates string/symbol +name+ like the
      # +artifact+ reader; the reserved "__suspend__" key is not a checkpoint.
      def checkpoint_result(name)
        state&.[](name.to_s)
      end

      # Finds a recorded artifact (Spec 7) by name, tolerating string- or
      # symbol-keyed hashes so it works before and after a json round-trip. Returns
      # the artifact hash or nil.
      def artifact(name)
        (artifacts || []).find { |a| (a["name"] || a[:name]) == name.to_s }
      end

      # Returns just the stored body of a named artifact (Spec 11 R4), or nil when
      # absent. Nexo exposes content only — serving files stays the host
      # controller's job (no Nexo routes/controllers for artifacts).
      def artifact_content(name)
        artifact(name)&.then { |a| a["content"] || a[:content] }
      end

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

      # Persists the run's checkpoint/suspend +state+ (Spec 13) without bumping
      # +updated_at+ — checkpoints accrue during a run just like events/artifacts,
      # so each shouldn't count as a full touch. The +state+ json object is
      # read/written by {Workflow#checkpoint} with string keys, so it round-trips
      # identically to the Memory store.
      def save_state!
        save!(touch: false)
      end

      private

      def assign_run_id
        self.id = Nexo.generate_run_id if id.blank?
      end
    end
  end
end
