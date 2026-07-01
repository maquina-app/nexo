# frozen_string_literal: true

module Nexo
  # Storage seam for {Workflow} runs. Two interchangeable backends expose an
  # identical create/find interface and return run objects responding to the
  # same shape, which is what lets one {Workflow} implementation drive either
  # the in-memory store (plain Ruby) or the ActiveRecord store (Rails).
  #
  # A run object responds to: +id+, +workflow_class+, +status+, +payload+,
  # +result+, +error+, +events+, plus +update!(attrs)+, +push_event(event)+,
  # and +save_events!+.
  module RunStore
    # Selects a backend: the ActiveRecord store when both ::ActiveRecord::Base
    # and Nexo::WorkflowRun are defined (the Rails path), otherwise the in-memory
    # store. With no Rails loaded the AR check short-circuits, so the plain-Ruby
    # path never references ActiveRecord.
    def self.default
      if defined?(::ActiveRecord::Base) && defined?(Nexo::WorkflowRun)
        ActiveRecord.new
      else
        Memory.new
      end
    end

    # In-memory backend used by the plain-Ruby path and the offline test suite.
    # Runs are held in a process-wide Hash keyed by their UUID id so that a run
    # created by {Workflow.run} is still findable through a *later*
    # {RunStore.default} call (e.g. {Workflow.logs}) — each call builds a fresh
    # Memory instance, but they all share the same underlying store, mirroring
    # how the ActiveRecord backend shares one database. Nothing is persisted to
    # disk; the store lives only for the process.
    class Memory
      # A run record with the shared store shape. +update!+ assigns attributes,
      # +push_event+ appends to the event log, and +save_events!+ is a no-op
      # (the AR backend persists; Memory keeps everything in the Struct).
      # Built with keyword arguments; a Struct defined without +keyword_init:+
      # accepts them on Ruby 3.2+, so (well within the 3.3 floor) +keyword_init:
      # true+ is unnecessary.
      Run = Struct.new(:id, :workflow_class, :status, :payload, :result, :error, :events) do
        def update!(attrs) = attrs.each { |k, v| self[k] = v }

        def push_event(ev) = events << ev

        def save_events! = nil
      end

      @runs = {}

      class << self
        # The shared run table. Ids are UUIDs, so runs from independent callers
        # never collide.
        attr_reader :runs

        # Clears the shared table. Intended for test isolation.
        def reset!
          @runs = {}
        end
      end

      def create(workflow_class:, payload:)
        run = Run.new(
          id: Nexo.generate_run_id,
          workflow_class: workflow_class,
          status: "pending",
          payload: payload,
          result: nil,
          error: nil,
          events: []
        )
        self.class.runs[run.id] = run
      end

      # Fetches a run by its UUID string id. A miss raises KeyError, which is
      # acceptable for v1.
      def find(id) = self.class.runs.fetch(id)
    end

    # ActiveRecord backend used by the Rails path. Delegates to the
    # {Nexo::WorkflowRun} model, which carries the same run shape.
    class ActiveRecord
      def create(workflow_class:, payload:)
        Nexo::WorkflowRun.create!(workflow_class: workflow_class, payload: payload, status: "pending")
      end

      def find(id) = Nexo::WorkflowRun.find(id)
    end
  end
end
