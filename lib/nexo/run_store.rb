# frozen_string_literal: true

require "json"
require "fileutils"

module Nexo
  # Storage seam for Workflow runs. Two interchangeable backends expose an
  # identical create/find interface and return run objects responding to the
  # same shape, which is what lets one Workflow implementation drive either
  # the in-memory store (plain Ruby) or the ActiveRecord store (Rails).
  #
  # A run object responds to: +id+, +workflow_class+, +status+, +payload+,
  # +result+, +error+, +events+, +artifacts+, +state+, plus +update!(attrs)+,
  # +push_event(event)+, +save_events!+, +push_artifact(artifact)+,
  # +save_artifacts!+, and +save_state!+ (Spec 13).
  module RunStore
    # Selects a backend: +Nexo.config.run_store+ when a host set one, else the
    # ActiveRecord store when both ::ActiveRecord::Base and Nexo::WorkflowRun are
    # defined (the Rails path), otherwise the in-memory store. With no Rails loaded
    # the AR check short-circuits, so the plain-Ruby path never references
    # ActiveRecord.
    #
    # The configured store wins over both, which is the only way a non-Rails host
    # gets durability: everything that survives a process — checkpoint, suspend,
    # resume, a run's recorded artifacts — is read back from the store, and Memory
    # dies with the process. See Disk.
    def self.default
      return Nexo.config.run_store if Nexo.config.run_store

      if defined?(::ActiveRecord::Base) && defined?(Nexo::WorkflowRun)
        ActiveRecord.new
      else
        Memory.new
      end
    end

    # In-memory backend used by the plain-Ruby path and the offline test suite.
    # Runs are held in a process-wide Hash keyed by their UUID id so that a run
    # created by Workflow.run is still findable through a *later*
    # RunStore.default call (e.g. Workflow.logs) — each call builds a fresh
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
      # Mutations serialize on the store-wide mutex (see Memory.mutex): the
      # process-wide store can be driven from multiple threads (Local#offload
      # workers, run_later under a threaded adapter, a multithreaded Puma host
      # without ActiveRecord), and on Rubies without a GVL a bare +<<+/+[]=+ can
      # lose events or corrupt the table.
      Run = Struct.new(:id, :workflow_class, :status, :payload, :result, :error, :events, :artifacts, :state) do
        def update!(attrs) = Memory.mutex.synchronize { attrs.each { |k, v| self[k] = v } }

        def push_event(ev) = Memory.mutex.synchronize { events << ev }

        def save_events! = nil

        def push_artifact(a) = Memory.mutex.synchronize { artifacts << a }

        def save_artifacts! = nil

        # No-op counterpart to the AR model's save_state! — the Struct member
        # already holds the checkpoint/suspend state in memory (Spec 13).
        def save_state! = nil

        # Read helpers mirroring Nexo::WorkflowRun so host code written against a
        # finished run behaves identically in plain Ruby and under Rails (the
        # "same run shape" contract covered only the write side before).
        def done? = status == "done"

        def failed? = status == "failed"

        def running? = status == "running"

        def queued? = status == "queued"

        def suspended? = status == "suspended"

        # The reason recorded when the run was suspended, or nil if it never was.
        def suspend_reason = state&.dig("__suspend__", "reason")

        # The stored result of a completed checkpoint(name), or nil.
        def checkpoint_result(name) = state&.[](name.to_s)

        # A recorded artifact by name (string/symbol tolerant), or nil.
        def artifact(name) = (artifacts || []).find { |a| (a["name"] || a[:name]) == name.to_s }

        # Just the stored body of a named artifact, or nil.
        def artifact_content(name) = artifact(name)&.then { |a| a["content"] || a[:content] }
      end

      @runs = {}
      @mutex = Mutex.new

      class << self
        # The shared run table. Ids are UUIDs, so runs from independent callers
        # never collide.
        attr_reader :runs

        # The store-wide lock guarding +runs+ and every run mutation. Not
        # reentrant, so no method that holds it calls another that grabs it.
        attr_reader :mutex

        # Clears the shared table. Intended for test isolation.
        def reset!
          @mutex.synchronize { @runs = {} }
        end
      end

      # Builds a fresh +"pending"+ Run (UUID id, empty events/artifacts/state) and
      # stores it in the process-wide table, returning it.
      def create(workflow_class:, payload:)
        run = Run.new(
          id: Nexo.generate_run_id,
          workflow_class: workflow_class,
          status: "pending",
          payload: payload,
          result: nil,
          error: nil,
          events: [],
          artifacts: [],
          state: {}
        )
        self.class.mutex.synchronize { self.class.runs[run.id] = run }
      end

      # Fetches a run by its UUID string id. A miss raises KeyError, which is
      # acceptable for v1.
      def find(id) = self.class.mutex.synchronize { self.class.runs.fetch(id) }

      # Atomically claims a +"suspended"+ run for resume: flips it to +"running"+
      # and returns true only if it was still suspended, so two concurrent resumes
      # can't both re-enter #call (Spec 13 double-execution guard). The status
      # flip is direct (not via #update!) to avoid re-entering the non-reentrant
      # mutex.
      def claim_for_resume!(run)
        self.class.mutex.synchronize do
          return false unless run.status == "suspended"

          run.status = "running"
          true
        end
      end
    end

    # ActiveRecord backend used by the Rails path. Delegates to the
    # Nexo::WorkflowRun model, which carries the same run shape.
    class ActiveRecord
      # Creates and persists a +"pending"+ Nexo::WorkflowRun row, returning it.
      def create(workflow_class:, payload:)
        Nexo::WorkflowRun.create!(workflow_class: workflow_class, payload: payload, status: "pending")
      end

      # Fetches a persisted run by id (raises +ActiveRecord::RecordNotFound+ on a miss).
      def find(id) = Nexo::WorkflowRun.find(id)

      # Atomically claims a +"suspended"+ run for resume with a single conditional
      # UPDATE, returning true only for the worker that won the row. This closes
      # the cross-process double-resume race the plain +find+-then-check couldn't:
      # a queued resume_later and a concurrent sync resume can't both re-enter.
      def claim_for_resume!(run)
        Nexo::WorkflowRun
          .where(id: run.id, status: "suspended")
          .update_all(status: "running") == 1
      end
    end

    # File-backed backend for a host with no database: one JSON document per run
    # under +dir+, rewritten whenever the run changes. This is what makes durability
    # available outside Rails — checkpoint, suspend/resume and a run's recorded
    # artifacts all read state back from the store, and Memory dies with the process.
    #
    #   Nexo.config.run_store = Nexo::RunStore::Disk.new(dir: "~/.local/state/myapp/runs")
    #
    # The Run is Memory's, subclassed: the shape and every read helper are shared, so
    # a host written against one store behaves identically on the other. Only the
    # +save_*+ hooks differ — they write the document. +push_event+/+push_artifact+
    # deliberately do NOT, because Workflow always calls the matching +save_*+ right
    # after, and persisting twice would double the writes for nothing.
    #
    # Scope, honestly: rewriting the whole document per change is fine for the run
    # sizes this is meant for (a CLI's own history) and wrong for a busy multi-worker
    # queue — that is what the ActiveRecord backend is for. +claim_for_resume!+ is
    # atomic within a process but NOT across processes; two machines resuming the
    # same run concurrently is out of scope. Runs are never pruned here: retention is
    # the host's policy, and +dir+ is a plain directory it can manage.
    class Disk
      # A Memory::Run that writes itself to +path+ whenever Workflow saves it.
      class Run < Memory::Run
        # Absolute path of this run's JSON document. Assigned by the store.
        attr_accessor :path

        # The three save hooks Workflow calls after mutating a run. Memory's are
        # no-ops because the Struct already holds everything; here they are the
        # whole point.
        def save_events! = persist!

        # Writes the run after Workflow appended an artifact.
        def save_artifacts! = persist!

        # Writes the run after Workflow stored checkpoint/suspend state.
        def save_state! = persist!

        # Assigns attributes (Memory's behaviour) and writes the run.
        def update!(attrs)
          super
          persist!
        end

        # Writes the document atomically — a temp file in the same directory, then
        # a rename — so a crash mid-write cannot leave a truncated run behind.
        def persist!
          return if path.nil?

          tmp = "#{path}.#{Process.pid}.tmp"
          ::File.write(tmp, JSON.generate(to_h.except(:path)))
          ::File.rename(tmp, path)
        end
      end

      # Serializes writes within the process, mirroring Memory's store-wide lock.
      MUTEX = Mutex.new

      # +dir+ is created on demand; +~+ is expanded.
      def initialize(dir:)
        @dir = ::File.expand_path(dir)
      end

      # The directory runs are written to.
      attr_reader :dir

      # Builds a fresh +"pending"+ Run, writes it, and returns it.
      def create(workflow_class:, payload:)
        run = Run.new(
          id: Nexo.generate_run_id, workflow_class: workflow_class, status: "pending",
          payload: payload, result: nil, error: nil, events: [], artifacts: [], state: {}
        )
        ::FileUtils.mkdir_p(@dir)
        run.path = path_for(run.id)
        run.persist!
        run
      end

      # Reads a run back by id. A miss raises KeyError, matching Memory.
      def find(id)
        path = path_for(id)
        raise KeyError, "run not found: #{id}" unless ::File.exist?(path)

        hydrate(JSON.parse(::File.read(path)), path)
      end

      # Every run in the directory, newest-written first. Not part of the store
      # contract Workflow calls — it is here because a host with a run directory
      # inevitably wants to list it ("what did the last run produce?").
      def all
        return [] unless ::File.directory?(@dir)

        Dir.glob(::File.join(@dir, "*.json"))
          .sort_by { |p| -::File.mtime(p).to_f }
          .filter_map do |p|
            hydrate(JSON.parse(::File.read(p)), p)
          rescue JSON::ParserError, SystemCallError
            # A half-written or hand-edited document must not break the listing.
            nil
          end
      end

      # Atomically claims a +"suspended"+ run for resume, re-reading from disk so a
      # stale in-memory copy cannot win. Within one process only — see the class
      # note.
      def claim_for_resume!(run)
        MUTEX.synchronize do
          current = find(run.id)
          return false unless current.status == "suspended"

          run.status = "running"
          run.path ||= path_for(run.id)
          run.persist!
          true
        end
      end

      private

      def path_for(id) = ::File.join(@dir, "#{id}.json")

      # Rebuilds a Run from its document. Missing members read as nil/empty rather
      # than raising, so a document written by an older version still loads.
      def hydrate(data, path)
        run = Run.new(
          id: data["id"], workflow_class: data["workflow_class"], status: data["status"],
          payload: data["payload"], result: data["result"], error: data["error"],
          events: data["events"] || [], artifacts: data["artifacts"] || [], state: data["state"] || {}
        )
        run.path = path
        run
      end
    end
  end
end
