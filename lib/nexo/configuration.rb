# frozen_string_literal: true

module Nexo
  # Holds the harness-wide defaults. Accessed through {Nexo.config} and
  # mutated through {Nexo.configure}. Every default is safe-by-default and
  # provider-neutral — there is intentionally no hardcoded model.
  class Configuration
    # The default ruby_llm model id. +nil+ means none chosen — provider-neutral.
    attr_accessor :default_model

    # The default sandbox: +:virtual+ (in-memory, zero host access).
    attr_accessor :default_sandbox

    # The default permission mode: +:read_only+.
    attr_accessor :default_permissions

    # Where SKILL.md packages live. Rails-aware: +app/skills+ under the app root.
    attr_accessor :skills_path

    # Concurrency mode (Spec 5): +:threaded+ (default) | +:async+. This is the
    # single switch that gates the {Sandboxes::Local} offload path — under
    # +:async+ its blocking file/shell I/O runs on a worker thread so it does not
    # stall a fiber reactor; under +:threaded+ it runs inline (zero overhead,
    # byte-for-byte the Spec 1 behavior). It does NOT gate {Nexo.concurrent},
    # which always runs its own reactor when called.
    attr_accessor :concurrency

    # Max in-flight tasks for {Nexo.concurrent} fan-out (Spec 5), default +8+.
    # The single most important knob for staying under provider rate limits.
    attr_accessor :max_in_flight

    # Whether {Workflow} buffers events in memory and flushes once at the end of
    # a run instead of persisting per +emit+ (Spec 5), default +false+. Buffering
    # avoids a blocking per-event DB write under a fiber reactor.
    attr_accessor :buffer_workflow_events

    # The host +acts_as_chat+ model that stores {Nexo::Session} threads (Spec 10),
    # given as a **String** class name (default +"Chat"+ — ruby_llm's own default).
    # It is constantized lazily at resume time so plain Ruby / no-ActiveRecord
    # paths never reference an AR constant, mirroring how {RunStore} only touches
    # {Nexo::WorkflowRun} when it is defined. The host app owns this model (columns
    # + a unique +(agent_name, instance_id)+ index); Nexo ships no migration for it.
    attr_accessor :session_chat_model

    # Whether to mirror run event notifications over Turbo Streams (Spec 11 R2),
    # default +false+ (safe-by-default). When true and turbo-rails is present, the
    # engine subscribes {Nexo::TurboBroadcaster} at boot. The plain
    # +nexo.workflow.event+/+nexo.workflow.status+ notifications fire regardless —
    # this only gates the opt-in Turbo mirror.
    attr_accessor :broadcast_events

    # The ActiveJob queue {Workflow.run_later} enqueues onto (Spec 11 R1), default
    # +nil+ → ActiveJob's default queue. Set to a symbol (e.g. +:nexo+) to route
    # workflow jobs to a dedicated queue.
    attr_accessor :job_queue

    def initialize
      @default_model = nil # provider-neutral: NO hardcoded default
      @default_sandbox = :virtual # safe default
      @default_permissions = :read_only # safe default
      @skills_path = default_skills_path
      @concurrency = :threaded # async is opt-in; :threaded stays the default
      @max_in_flight = 8
      @buffer_workflow_events = false
      @session_chat_model = "Chat" # ruby_llm's own default acts_as_chat host
      @broadcast_events = false # safe default: opt in to the Turbo mirror
      @job_queue = nil # nil → ActiveJob's default queue
    end

    private

    def default_skills_path
      if defined?(::Rails) && ::Rails.respond_to?(:root) && ::Rails.root
        ::Rails.root.join("app/skills").to_s
      else
        "skills"
      end
    end
  end
end
