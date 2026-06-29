# frozen_string_literal: true

require "time"

module Nexo
  # A finite-job lifecycle primitive. Subclass {Workflow}, implement
  # +#call(payload)+, and run it with +MyWorkflow.run(payload)+ to get back a
  # persisted run record carrying a stable runId, status, payload, result,
  # error, and an ordered, inspectable event log.
  #
  #   class SummarizeDocument < Nexo::Workflow
  #     def call(payload)
  #       emit(:started, doc_id: payload[:doc_id])
  #       summary = payload[:text].to_s.slice(0, 280)
  #       emit(:summarized, length: summary.length)
  #       { summary: summary }
  #     end
  #   end
  #
  #   run = SummarizeDocument.run(doc_id: 123, text: "Long text…")
  #   run.status  # => "done"
  #   run.result  # => { "summary" => "Long text…" }  (string keys after round-trip)
  #
  # +#call+ receives a symbol-keyed payload, but +run.payload+ and +run.result+
  # read back string-keyed (top-level) in both backends — the Hash keys are
  # stringified before storage, matching what the ActiveRecord json column would
  # round-trip to, so a single workflow drives either store consistently.
  #
  # The lifecycle records failures but never swallows them: a raising +#call+
  # leaves the run +"failed"+ with +error+ set *and* re-raises. (This is the
  # opposite of a Nexo *tool* failure, which returns +{ error: … }+ and never
  # raises into the agent loop.) Workflows are not resumable — an interrupted
  # run is abandoned and you start a new one.
  class Workflow
    class << self
      # Runs the workflow end to end: creates a run record (status "pending"),
      # marks it "running", invokes the subclass's +#call+ with a symbol-keyed
      # payload, and records the outcome. On success the run is "done" with the
      # return value as +result+; on any raised error it is "failed" with the
      # message as +error+ and the exception is re-raised. Returns the run.
      def run(payload = {})
        store = Nexo::RunStore.default
        run = store.create(workflow_class: name, payload: stringify(payload))
        run.update!(status: "running")

        instance = new(run)
        result = instance.call(symbolize(payload))
        run.update!(status: "done", result: stringify_keys(result))
        run.save! if run.respond_to?(:save!)
        run
      rescue => e
        if run
          run.update!(status: "failed", error: e.message)
          run.save! if run.respond_to?(:save!)
        end
        raise
      end

      # Looks up a run by its UUID string id through whichever store
      # {RunStore.default} selects, yields each event when a block is given, and
      # returns the ordered +events+ array. Works identically in plain Ruby and
      # under Rails.
      def logs(id)
        run = Nexo::RunStore.default.find(id)
        run.events.each { |ev| yield ev if block_given? }
        run.events
      end

      private

      def stringify(hash) = hash.transform_keys(&:to_s)

      def symbolize(hash) = hash.transform_keys(&:to_sym)

      # Stringifies a result's top-level Hash keys so run.result reads back
      # string-keyed in the Memory store too (the AR json column does this on its
      # own). Non-Hash results (a String, Array, etc.) pass through untouched.
      def stringify_keys(result) = result.is_a?(Hash) ? stringify(result) : result
    end

    def initialize(run)
      @run = run
    end

    # Subclasses implement the work here. The +payload+ is symbol-keyed; the
    # returned value becomes the run's +result+ (read back string-keyed).
    def call(payload)
      raise NotImplementedError, "#{self.class} must implement #call(payload)"
    end

    # Appends an event to the run's ordered log and persists it incrementally.
    # The event's own keys ("type"/"data"/"at") are strings so the record reads
    # back the same shape after the ActiveRecord backend's JSON round-trip; the
    # caller-supplied +data+ hash is stored verbatim (symbol keys survive the
    # in-memory store, stringify through the json column). Returns the event hash.
    def emit(type, data = {})
      ev = {"type" => type.to_s, "data" => data, "at" => Time.now.utc.iso8601}
      @run.push_event(ev)
      @run.save_events! if @run.respond_to?(:save_events!)
      ev
    end
  end
end
