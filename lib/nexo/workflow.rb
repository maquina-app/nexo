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
  # raises into the agent loop.) An orphaned +"running"+ run (crashed worker) is
  # abandoned — sweep it with {.reconcile_interrupted!}.
  #
  # A run can pause and continue on purpose, though (Spec 13): call {#suspend!}
  # mid-+#call+ to leave the run +"suspended"+ (not failed), then {.resume} /
  # {.resume_later} to re-enter +#call+ from the top. {#checkpoint} guards the
  # expensive/side-effectful steps so resume skips already-paid-for work — see the
  # "Durable workflows" README section for the honest resume semantics.
  class Workflow
    # Control-flow signal raised by {#suspend!} and caught by {.execute} to pause
    # a run durably — NOT a failure. It transitions the run to +"suspended"+
    # (never +"failed"+) and returns the run to the caller rather than re-raising.
    # Carries the +reason+ (surfaced to a host UI) and an optional +resume_key+
    # (persisted so a host can correlate which resume it is awaiting — Spec 13 Q2).
    class Suspended < StandardError
      attr_reader :reason, :resume_key

      def initialize(reason, resume_key = nil)
        @reason = reason
        @resume_key = resume_key
        super("workflow suspended: #{reason}")
      end
    end

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

      # The {Agent} subclass this workflow drives (Spec 8). Follows the same
      # read-vs-write ivar convention as {.sandbox}/{.cwd}: with no argument it
      # reads (default +nil+ — a workflow need not drive an agent); with one it
      # sets. Consumed by {#run_agent}, which binds the agent to the run's shared
      # sandbox. There is no per-call override — this macro is the only source.
      def agent(klass = nil)
        klass.nil? ? @agent : (@agent = klass)
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
        run = Nexo::RunStore.default.create(workflow_class: name, payload: stringify(payload))
        # Pass the caller's ORIGINAL symbolized payload (nested Ruby values intact)
        # — the sync path never crosses a JSON/DB boundary, so it must not read back
        # the store-normalized run.payload. Only the async job symbolizes run.payload.
        execute(run, payload: symbolize(payload), buffer_events: buffer_events)
      end

      # Enqueues the workflow on the host's ActiveJob adapter and hands back the run
      # immediately (status "queued") so a controller can return while the work
      # happens in the background. The job carries only the run id — the payload
      # lives on the run record.
      #
      # Requires ActiveJob (Rails): with no ActiveJob loaded this raises
      # {Nexo::MissingDependencyError} pointing at {.run} for synchronous execution.
      # +queue:+ (default {Nexo.config.job_queue}) routes the job to a named queue;
      # +nil+ uses ActiveJob's default queue.
      #
      # It is only meaningful with a shared run store — the AR store plus a real
      # adapter, so a worker in another process finds the run in the database. Under
      # the +:inline+/+:test+ adapter the job runs in-process, so the Memory store is
      # also reachable. Not resumable: a crashed or retried job re-runs +#call+ from
      # scratch (Nexo adds no +retry_on+); pair with {.reconcile_interrupted!} to
      # catch runs orphaned in +"running"+.
      def run_later(payload = nil, queue: Nexo.config.job_queue, **kwargs)
        unless defined?(::ActiveJob)
          raise Nexo::MissingDependencyError,
            "run_later requires ActiveJob (Rails). Use `run` for synchronous execution."
        end
        payload ||= kwargs
        run = Nexo::RunStore.default.create(workflow_class: name, payload: stringify(payload))
        run.update!(status: "queued")
        run.save! if run.respond_to?(:save!)
        job = Nexo::WorkflowJob
        job = job.set(queue: queue) if queue
        job.perform_later(run.id)
        run
      end

      # Continues a +"suspended"+ run synchronously (Spec 13): re-instantiates the
      # workflow from +run.workflow_class+ and re-runs +#call+ **from the top** with
      # the run's original payload, making +input+ available via {#resume_input}.
      #
      # This is re-entry, NOT replay — Ruby has no transparent continuation capture.
      # Everything *outside* a {#checkpoint} re-runs; only checkpoint-guarded work is
      # skipped (its stored result is returned without re-running the block). Guard
      # every side effect and expensive step with a checkpoint; idempotency of the
      # non-checkpointed code is the author's responsibility.
      #
      # Loads the run through {RunStore.default}, so it works with either store —
      # but durable *cross-process* resume needs the ActiveRecord store (a Memory
      # run doesn't survive the process); Memory resume is valid in-process.
      # Raises {Nexo::Error} for a run that is not currently +"suspended"+.
      def resume(run_id, input = {})
        run = Nexo::RunStore.default.find(run_id)
        unless run.status == "suspended"
          raise Nexo::Error, "run #{run_id} is not suspended (#{run.status})"
        end
        # Object.const_get (not String#constantize) so resume works in plain Ruby
        # without ActiveSupport's core_ext — mirrors Nexo::Session (Spec 10).
        klass = Object.const_get(run.workflow_class)
        klass.execute(run, payload: symbolize(run.payload), resume_input: input)
      end

      # Enqueues a durable, cross-process resume of a +"suspended"+ run (Spec 13 Q4),
      # mirroring {.run_later}: the job carries the run id **plus** the resume +input+
      # (the payload still lives on the run — only the input travels). +input+ must be
      # ActiveJob/json-serializable. Returns the run (still +"suspended"+ until the
      # job picks it up and re-enters {.resume}'s guard).
      #
      # Requires ActiveJob (Rails): without it this raises {Nexo::MissingDependencyError}
      # pointing at {.resume} for synchronous execution. +queue:+ (default
      # {Nexo.config.job_queue}) routes the job exactly like {.run_later}.
      def resume_later(run_id, input = {}, queue: Nexo.config.job_queue)
        unless defined?(::ActiveJob)
          raise Nexo::MissingDependencyError,
            "resume_later requires ActiveJob (Rails). Use `resume` for synchronous execution."
        end
        run = Nexo::RunStore.default.find(run_id)
        job = Nexo::WorkflowJob
        job = job.set(queue: queue) if queue
        job.perform_later(run.id, input)
        run
      end

      # Executes an already-created run: "running" → +#call+ → "done"/"failed",
      # flushing buffered events in the ensure (on both success and failure) and
      # firing a status notification on each transition. Shared by {.run} (sync) and
      # {WorkflowJob#perform} (async). Re-raises on failure.
      #
      # +payload:+ is symbol-keyed: {.run} passes the caller's original (nested Ruby
      # values intact); the job passes the JSON-normalized +run.payload+ symbolized.
      #
      # +resume_input:+ (Spec 13, default +{}+) is the symbol-keyed input handed to
      # {.resume}/{.resume_later}; it is exposed to +#call+ via {#resume_input} and
      # is +{}+ on the first (non-resume) pass. A +#call+ that raises {Suspended}
      # (via {#suspend!}) leaves the run +"suspended"+ (a non-failure outcome) and
      # returns it — completed {#checkpoint}s persist and are skipped on resume.
      def execute(run, payload:, buffer_events: Nexo.config.buffer_workflow_events, resume_input: {})
        run.update!(status: "running")
        run.save! if run.respond_to?(:save!)
        notify_status(run)

        instance = new(run, buffer_events: buffer_events)
        instance.instance_variable_set(:@resume_input, resume_input)
        result = instance.call(payload)
        run.update!(status: "done", result: stringify_keys(result))
        run.save! if run.respond_to?(:save!)
        notify_status(run)
        run
      rescue Nexo::Workflow::Suspended => s
        # A durable pause, NOT a failure: mark "suspended", record the suspend
        # metadata under the reserved "__suspend__" state key (alongside any
        # completed checkpoints), broadcast the transition, and RETURN the run —
        # never re-raise. The $!-aware ensure below still flushes buffered events
        # ($! is nil here, since the signal is caught, not propagating).
        run.update!(status: "suspended",
          state: (run.state || {}).merge("__suspend__" => {
            "reason" => s.reason, "resume_key" => s.resume_key, "at" => Time.now.utc.iso8601
          }))
        run.save! if run.respond_to?(:save!)
        notify_status(run)
        run
      rescue => e
        if run
          run.update!(status: "failed", error: e.message)
          run.save! if run.respond_to?(:save!)
          notify_status(run)
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

      # Broadcasts a run's status transition over ActiveSupport::Notifications
      # (Spec 11 R2) — a no-op without ActiveSupport, so the plain-Ruby core stays
      # decoupled. Carries only the run id and status; no payload/credentials. Fired
      # by {.execute} on each transition (running → done/failed).
      def notify_status(run)
        return unless defined?(::ActiveSupport::Notifications)

        ::ActiveSupport::Notifications.instrument(
          "nexo.workflow.status", run_id: run.id, status: run.status
        )
      end

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

    # Runs +name+'s block **once** and stores its json-serializable result under
    # +name.to_s+ in the run's +state+ — the primitive that makes resume cheap and
    # side-effect-safe (Spec 13). On a later run/resume of the *same* run a present
    # checkpoint returns the stored value **without** re-running the block:
    #
    #   fetched = checkpoint(:fetch) { expensive_api_call(payload[:id]) }
    #   published = checkpoint(:publish) { publish!(fetched) }
    #
    # Persists **immediately** (like artifacts, not buffered like events), so a
    # completed checkpoint survives a subsequent {#suspend!}. Values must be
    # json-serializable — they round-trip the store exactly like +result+/+events+.
    #
    # Do NOT call {#suspend!} inside a checkpoint block (undefined — v1 unsupported),
    # and do NOT name a checkpoint +"__suspend__"+ (reserved for suspend metadata).
    # A crash *inside* a checkpoint re-runs that checkpoint on resume (at-least-once
    # for the in-flight step) — guard side effects accordingly.
    def checkpoint(name)
      key = name.to_s
      store = @run.state || {}
      return store[key] if store.key?(key)

      value = yield
      @run.state = store.merge(key => value)
      @run.save_state! if @run.respond_to?(:save_state!)
      value
    end

    # Pauses the run durably (Spec 13): raises {Suspended}, which {.execute} catches
    # to mark the run +"suspended"+ (a non-failure outcome) and return it to the
    # caller. Call this **outside** a checkpoint block. +reason+ is surfaced to a
    # host UI; the optional +resume_key+ is persisted so a host can correlate which
    # resume it is awaiting. Continue the run later with {.resume}/{.resume_later}.
    def suspend!(reason:, resume_key: nil)
      raise Suspended.new(reason, resume_key)
    end

    # The symbol-keyed input passed to {.resume}/{.resume_later} (Spec 13). It is
    # +{}+ on the first (non-resume) pass, so a workflow gates on it to decide
    # whether to {#suspend!} or proceed:
    #
    #   suspend!(reason: "needs approval") unless resume_input[:approved]
    def resume_input = @resume_input || {}

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
      # Live broadcast (Spec 11 R2): fires regardless of buffering — persistence
      # stays separate/buffered above, but the notification is live. A no-op without
      # ActiveSupport, so this is exactly the Spec 2 emit in the plain-Ruby core.
      notify_event(ev)
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

    # Drives the workflow's declared {.agent} (Spec 8), bound to *this* run's
    # sandbox (Spec 7), forwarding every +(type, payload)+ event the agent's loop
    # yields into the run log as an +agent_*+ event, and ensuring the agent is
    # closed afterward (tearing down any memoized MCP servers from Spec 6).
    # Returns the agent's response object (read +response.content+).
    #
    # Composition only — no new loop, no orchestration engine: it wires the
    # existing {Agent#prompt} + +before_tool_call+/+after_tool_result+ seam
    # (source: {Loops::RubyLLM}) through the existing {#emit} path, so the events
    # honor the run's +buffer_events+ setting and persist in both run stores with
    # no extra wiring.
    #
    # Shared-sandbox precedence: under +run_agent+ the agent uses the workflow's
    # sandbox; the agent's own +sandbox+ class macro is ignored (it only applies
    # when the agent runs standalone via +.new.prompt+). The agent keeps its own
    # +permissions+/+skills+/+mcp+/+mcp_allow+ — the workflow provides the *where*
    # (sandbox), the agent owns the *what* (permissions) and *how* (skills). Driving
    # an agent never widens its authority; its safe default (+:read_only+) is
    # untouched. Raises {ConfigurationError} when no +agent+ is declared.
    def run_agent(prompt, max_turns: 25)
      klass = self.class.agent or raise Nexo::ConfigurationError,
        "#{self.class} has no `agent` declared; add `agent MyAgent`"
      agent = klass.new(sandbox: sandbox)
      agent.prompt(prompt, max_turns: max_turns) do |type, payload|
        emit(:"agent_#{type}", serializable(type, payload))
      end
    ensure
      # Guarded so it's safe if Spec 6 (Agent#close) isn't present in the agent.
      agent.close if agent.respond_to?(:close)
    end

    private

    # Broadcasts a single event over ActiveSupport::Notifications (Spec 11 R2) as it
    # is emitted — a no-op without ActiveSupport, so the plain-Ruby core's {#emit} is
    # exactly Spec 2. Fires live even when persistence is buffered. The payload
    # carries only the run id and the already-built event hash (what {#emit} was
    # given) — no extra payload/credential dump.
    def notify_event(ev)
      return unless defined?(::ActiveSupport::Notifications)

      ::ActiveSupport::Notifications.instrument(
        "nexo.workflow.event", run_id: @run.id, event: ev
      )
    end

    # Reduces a loop event payload to a plain, json-safe Hash *before* {#emit},
    # so it round-trips through both the Memory store and the ActiveRecord json
    # column — a raw +ruby_llm+ object (a {RubyLLM::ToolCall}, a tool result, a
    # response {RubyLLM::Message}) is never emitted. The reducer is type-aware
    # (the event +type+ selects the fields rather than guessing from object shape)
    # and degrades gracefully — a missing field falls back to +to_s+ rather than
    # raising, so observability never breaks the run.
    #
    # Field mapping (VERIFIED Group 0, ruby_llm 1.16.0):
    # - +:tool_call+   → +ToolCall#name+ + +#arguments+ (or a plain +{name:, args:}+ Hash).
    # - +:tool_result+ → the tool's return value: a String (ok), or a +{error:}+/
    #   +{content:}+ Hash from a Nexo gated tool (+ok+ derived from +error+).
    # - +:done+        → the final response +Message#content+.
    def serializable(type, payload)
      case type
      when :tool_call then reduce_tool_call(payload)
      when :tool_result then reduce_tool_result(payload)
      when :done then reduce_done(payload)
      else {"value" => payload.to_s}
      end
    end

    def reduce_tool_call(payload)
      if payload.is_a?(Hash)
        h = payload.transform_keys(&:to_s)
        {"name" => h["name"].to_s, "args" => h["args"] || h["arguments"]}
      elsif payload.respond_to?(:name)
        {"name" => payload.name.to_s, "args" => tool_call_args(payload)}
      else
        {"value" => payload.to_s}
      end
    end

    def tool_call_args(payload)
      return payload.arguments if payload.respond_to?(:arguments)
      return payload.args if payload.respond_to?(:args)

      nil
    end

    def reduce_tool_result(payload)
      unless payload.is_a?(Hash)
        # A bare content value (e.g. file contents) — a successful read.
        return {"ok" => true, "content" => payload.to_s}
      end

      h = payload.transform_keys(&:to_s)
      error = h["error"]
      ok = h.key?("ok") ? h["ok"] : error.nil?
      content = h["content"] || h["output"] || error
      out = {"ok" => ok}
      out["content"] = content.to_s unless content.nil?
      out
    end

    def reduce_done(payload)
      content = payload.respond_to?(:content) ? payload.content : payload
      {"content" => content.to_s}
    end

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
