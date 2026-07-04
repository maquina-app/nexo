# frozen_string_literal: true

require "time"
require "erb"

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
      # The sandbox this workflow's runs stage inputs into and write artifacts to
      # (Spec 7). Follows the same read-vs-write ivar convention as {Agent}'s
      # macros: with no argument it reads (default +:virtual+ — safe, in-memory);
      # with one it sets. Resolution is lazy — a data-only workflow that never
      # stages or emits artifacts builds nothing (see {#sandbox}).
      def sandbox(value = nil)
        value.nil? ? (@sandbox || :virtual) : (@sandbox = value)
      end

      # The working directory used when this workflow's sandbox is +:local+. The
      # +Dir.pwd+ default is evaluated at *read* time (in the macro body), so the
      # working directory is captured when the sandbox is actually resolved, not
      # at class-definition time. Never read for a +:virtual+ workflow.
      def cwd(value = nil)
        value.nil? ? (@cwd || Dir.pwd) : (@cwd = value)
      end

      # One-shot boot/deploy sweep (Spec 7 R6) that rewrites runs orphaned in
      # +"running"+ to +"interrupted"+ so a crashed worker doesn't leave zombie
      # runs. Touches *only* +"running"+ rows — +"done"+ and +"failed"+ are never
      # rewritten. Under Rails it is a single +update_all+; offline it iterates the
      # Memory store. NEVER auto-invoked — call it from a boot hook or the shipped
      # +nexo:reconcile+ rake task.
      #
      # This is not a liveness check: it cannot distinguish an orphaned run from
      # one genuinely running in another process. Run it once at boot, before any
      # worker starts new runs. Returns the number of runs rewritten.
      def reconcile_interrupted!
        if defined?(::ActiveRecord::Base) && defined?(Nexo::WorkflowRun)
          Nexo::WorkflowRun.where(status: "running").update_all(status: "interrupted")
        else
          running = Nexo::RunStore::Memory.runs.each_value.select { |run| run.status == "running" }
          running.each { |run| run.update!(status: "interrupted") }
          running.size
        end
      end

      # Runs the workflow end to end: creates a run record (status "pending"),
      # marks it "running", invokes the subclass's +#call+ with a symbol-keyed
      # payload, and records the outcome. On success the run is "done" with the
      # return value as +result+; on any raised error it is "failed" with the
      # message as +error+ and the exception is re-raised. Returns the run.
      #
      # +buffer_events:+ (Spec 5, default {Nexo.config.buffer_workflow_events})
      # controls persistence of the event log. When +false+ each +emit+ persists
      # immediately (Spec 2 behavior). When +true+ events are buffered in memory
      # and flushed to the store exactly once — the flush runs in the +ensure+ so
      # events land on both success and failure. Buffering avoids a blocking
      # per-event DB write under a fiber reactor.
      #
      # The payload keeps its Spec 2 shape: it may be passed as an explicit Hash
      # (+run({doc_id: 1}, buffer_events: true)+) or as bare keywords
      # (+run(doc_id: 1)+) — when no positional Hash is given, the collected
      # keywords (minus +buffer_events:+) become the payload. This keeps the
      # documented +Workflow.run(doc_id: …, text: …)+ form working now that
      # +buffer_events:+ is a real keyword.
      def run(payload = nil, buffer_events: Nexo.config.buffer_workflow_events, **kwargs)
        payload ||= kwargs
        store = Nexo::RunStore.default
        run = store.create(workflow_class: name, payload: stringify(payload))
        run.update!(status: "running")

        instance = new(run, buffer_events: buffer_events)
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
      ensure
        # Flush buffered events on both success and failure. $! is the exception
        # already propagating out of #call (nil on the success path); a flush
        # failure must never mask that original error, so it is only surfaced
        # when the workflow itself succeeded.
        pending = $!
        begin
          instance&.flush_events!
        rescue
          raise if pending.nil?
        end
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

    def initialize(run, buffer_events: false)
      @run = run
      @buffer_events = buffer_events
      @event_buffer = []
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
      if @buffer_events
        # Defer the DB hit — accumulate in memory and persist once in
        # {#flush_events!} (called from Workflow.run's ensure).
        @event_buffer << ev
      else
        @run.push_event(ev)
        @run.save_events! if @run.respond_to?(:save_events!)
      end
      ev
    end

    # Replays any buffered events through the run and persists them in a single
    # +save_events!+, then clears the buffer. A no-op when buffering is off or the
    # buffer is empty. Called from {Workflow.run}'s +ensure+, so buffered events
    # are saved on both success and failure. Idempotent (a second call, e.g. if a
    # workflow calls it explicitly, finds an empty buffer and does nothing).
    def flush_events!
      return unless @buffer_events && @event_buffer.any?

      @event_buffer.each { |ev| @run.push_event(ev) }
      @run.save_events! if @run.respond_to?(:save_events!)
      @event_buffer.clear
    end

    # The run's sandbox (Spec 7), resolved lazily from the class-level {.sandbox}
    # macro and memoized. Built on first touch — by {#stage}, {#artifact}, or a
    # workflow reading/writing files directly — so a data-only workflow that never
    # calls any of them constructs nothing new and keeps the Spec 2 hot path
    # byte-for-byte unchanged.
    def sandbox
      @sandbox ||= resolve_sandbox(self.class.sandbox)
    end

    # Stages provided files into the run's sandbox before work begins (Spec 7 R2).
    # Accepts either a Hash +{ "path" => "content" }+ or an Array of
    # +{ path:, content: }+ hashes; both normalize to +[path, content]+ pairs.
    # Each pair is written via +sandbox.write+. Emits a +:staged+ event carrying
    # the count (reusing the existing {#emit} path) and returns the number of
    # files staged.
    def stage(files)
      pairs = files.is_a?(Hash) ? files.to_a : files.map { |f| [f[:path], f[:content]] }
      pairs.each { |path, content| sandbox.write(path, content) }
      emit(:staged, count: pairs.size)
      pairs.size
    end

    # Records a named deliverable on the run (Spec 7 R3). The body comes from
    # either +content:+ (used verbatim) or +from:+ (a **trusted, developer-authored**
    # ERB template — a real disk file when +File.exist?(from)+, else a staged
    # sandbox path via +sandbox.read+ — rendered with the given +locals+).
    #
    # SECURITY: ERB executes arbitrary Ruby. A +from:+ template must be a trusted
    # file you control — NEVER model output or user-uploaded content. Templates are
    # code, not data (see README).
    #
    # The body is written to the sandbox at +/artifacts/<name>+ (so scripts/agents
    # can read it during the run) and recorded on the run as a string-keyed hash
    # +{"name" =>, "content" =>, "at" =>}+, matching how {#emit} string-keys events
    # so Memory and the AR json column round-trip identically. Artifacts persist
    # immediately (never buffered). Raises {Nexo::Error} when neither +content:+ nor
    # +from:+ produces a body. Returns the artifact hash.
    def artifact(name, content: nil, from: nil, locals: {})
      body = content
      if from
        template = File.exist?(from) ? File.read(from) : sandbox.read(from)
        body = ERB.new(template, trim_mode: "-").result_with_hash(locals)
      end
      raise Nexo::Error, "artifact #{name} needs content: or from:" if body.nil?

      sandbox.write("/artifacts/#{name}", body)
      art = {"name" => name.to_s, "content" => body, "at" => Time.now.utc.iso8601}
      @run.push_artifact(art)
      @run.save_artifacts! if @run.respond_to?(:save_artifacts!)
      art
    end

    private

    # Mirrors {Agent#resolve_sandbox}: a pre-built {Sandbox} passes through;
    # +:virtual+ builds an in-memory {Sandboxes::Virtual}; +:local+ builds a
    # {Sandboxes::Local} rooted at the class-level {.cwd}. An unknown value is a
    # configuration error.
    def resolve_sandbox(value)
      return value if value.is_a?(Sandbox)

      case value
      when :virtual then Sandboxes::Virtual.new
      when :local then Sandboxes::Local.new(cwd: self.class.cwd)
      else raise ConfigurationError, "unknown sandbox: #{value.inspect}"
      end
    end
  end
end
