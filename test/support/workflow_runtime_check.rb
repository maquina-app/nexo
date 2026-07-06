# frozen_string_literal: true

# Exercises the Spec 11 Rails runtime (run_later over ActiveJob, live event/status
# notifications, WorkflowRun status scopes/predicates, artifact access) against an
# in-memory SQLite database with the :inline queue adapter and a STUBBED model
# (ruby_llm-test). Run in a SEPARATE process (see test/workflow_runtime_test_rails.rb):
# loading ActiveRecord/ActiveJob into the main offline suite would flip
# RunStore.default to the AR backend and load a live transport for every other test.
#
# The :inline adapter runs the job in-process on enqueue, so both the AR store and
# (if it were selected) the Memory store are reachable. Prints OK markers the parent
# asserts on; aborts (non-zero exit) on any mismatch.

# ruby_llm reads its bundled models.json (UTF-8) during model resolution; force
# UTF-8 so this child is environment-independent like the core suite.
Encoding.default_external = Encoding::UTF_8 unless Encoding.default_external == Encoding::UTF_8

require "active_record"
require "active_job"
require "active_support/core_ext/string" # constantize used by WorkflowJob#perform

lib = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require "nexo_ai"            # provides Nexo.generate_run_id; Zeitwerk ignores the model/job
require "nexo/workflow_run"  # ActiveRecord present → the guarded model body defines
require "nexo/workflow_job"  # ActiveJob present → the guarded job body defines

abort "FAIL: WorkflowJob not defined" unless defined?(Nexo::WorkflowJob)
abort "FAIL: RunStore did not select the AR backend" unless
  Nexo::RunStore.default.is_a?(Nexo::RunStore::ActiveRecord)

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

# Build the schema by running the real migration template (also confirms the
# json-column / string-UUID-PK migration is valid against SQLite).
require File.expand_path("../../lib/generators/nexo/workflows/templates/create_nexo_workflow_runs.rb", __dir__)
ActiveRecord::Migration.verbose = false
CreateNexoWorkflowRuns.new.migrate(:up)

# Run the job in-process on enqueue so the just-created run is findable.
ActiveJob::Base.logger = Logger.new(IO::NULL)
ActiveJob::Base.queue_adapter = :inline

# Workflows defined at top level so run.workflow_class ("Adder"/"Reporter") is
# constantizable inside WorkflowJob#perform.
class Adder < Nexo::Workflow
  def call(payload)
    emit(:adding, a: payload[:a], b: payload[:b])
    {sum: payload[:a] + payload[:b]}
  end
end

# Emits an event and records an artifact (Spec 7) so artifact_content can be asserted.
class Reporter < Nexo::Workflow
  def call(_payload)
    artifact("digest.md", content: "the body")
    emit(:reported, ok: true)
    {status: "reported"}
  end
end

# --- R1: run_later enqueues on ActiveJob and (inline) executes via the job to "done".
run = Adder.run_later(a: 2, b: 3)
abort "FAIL: run_later did not return a run" unless run.respond_to?(:id)
reloaded = Nexo::RunStore.default.find(run.id)
abort "FAIL: run_later status (#{reloaded.status.inspect})" unless reloaded.status == "done"
abort "FAIL: run_later result (#{reloaded.result.inspect})" unless reloaded.result["sum"] == 5
puts "RUN_LATER_OK"

# --- R1: the sync path still works unchanged.
sync = Adder.run(a: 10, b: 1)
abort "FAIL: sync status (#{sync.status.inspect})" unless sync.status == "done"
abort "FAIL: sync result (#{sync.result.inspect})" unless sync.result["sum"] == 11
puts "SYNC_RUN_OK"

# --- R2: a real subscriber to nexo.workflow.event receives events with run_id + type.
event_payloads = []
status_payloads = []
ev_sub = ActiveSupport::Notifications.subscribe("nexo.workflow.event") { |*, p| event_payloads << p }
st_sub = ActiveSupport::Notifications.subscribe("nexo.workflow.status") { |*, p| status_payloads << p }
Adder.run(a: 4, b: 5)
ActiveSupport::Notifications.unsubscribe(ev_sub)
ActiveSupport::Notifications.unsubscribe(st_sub)

abort "FAIL: no adding event (#{event_payloads.inspect})" unless
  event_payloads.any? { |p| p[:event]["type"] == "adding" }
abort "FAIL: event missing run_id" unless event_payloads.all? { |p| p[:run_id] }
# status transitions running -> done both broadcast.
seen_statuses = status_payloads.map { |p| p[:status] }
abort "FAIL: statuses (#{seen_statuses.inspect})" unless (%w[running done] - seen_statuses).empty?
abort "FAIL: status missing run_id" unless status_payloads.all? { |p| p[:run_id] }
puts "NOTIFICATIONS_OK"

# --- R3: status scopes + predicates return the right runs.
Nexo::WorkflowRun.delete_all
done_run = Nexo::WorkflowRun.create!(workflow_class: "Adder", status: "done", payload: {})
failed_run = Nexo::WorkflowRun.create!(workflow_class: "Adder", status: "failed", payload: {})
queued_run = Nexo::WorkflowRun.create!(workflow_class: "Adder", status: "queued", payload: {})
running_run = Nexo::WorkflowRun.create!(workflow_class: "Adder", status: "running", payload: {})

abort "FAIL: queued scope" unless Nexo::WorkflowRun.queued.pluck(:id) == [queued_run.id]
abort "FAIL: running scope" unless Nexo::WorkflowRun.running.pluck(:id) == [running_run.id]
abort "FAIL: finished scope" unless
  Nexo::WorkflowRun.finished.pluck(:id).sort == [done_run.id, failed_run.id].sort
abort "FAIL: done? predicate" unless done_run.done? && !done_run.failed?
abort "FAIL: failed? predicate" unless failed_run.failed?
abort "FAIL: queued? predicate" unless queued_run.queued?
abort "FAIL: running? predicate" unless running_run.running?
abort "FAIL: STATUSES constant" unless
  Nexo::WorkflowRun::STATUSES == %w[pending queued running done failed interrupted suspended]
puts "HELPERS_OK"

# --- Spec 13: durable suspend/resume over the AR store (cross-process shape).
class ApprovalFlow < Nexo::Workflow
  def call(payload)
    fetched = checkpoint(:fetch) { "doc-#{payload[:id]}" }
    suspend!(reason: "needs approval", resume_key: "k#{payload[:id]}") unless resume_input[:approved]
    checkpoint(:publish) { "published #{fetched}" }
    {done: true}
  end
end

suspended = ApprovalFlow.run(id: 9)
abort "FAIL: suspend status (#{suspended.status.inspect})" unless suspended.status == "suspended"
reloaded = Nexo::WorkflowRun.find(suspended.id)
abort "FAIL: suspend? predicate" unless reloaded.suspended?
abort "FAIL: suspend_reason (#{reloaded.suspend_reason.inspect})" unless reloaded.suspend_reason == "needs approval"
abort "FAIL: suspend resume_key" unless reloaded.state["__suspend__"]["resume_key"] == "k9"
abort "FAIL: pre-suspend checkpoint (#{reloaded.checkpoint_result("fetch").inspect})" unless
  reloaded.checkpoint_result("fetch") == "doc-9"
abort "FAIL: suspended scope" unless Nexo::WorkflowRun.suspended.pluck(:id).include?(suspended.id)

# Reconciliation must leave the suspended run untouched (intentional, not orphaned).
Nexo::Workflow.reconcile_interrupted!
abort "FAIL: reconcile touched suspended" unless Nexo::WorkflowRun.find(suspended.id).status == "suspended"

# resume (sync) re-enters #call from the top; the completed checkpoint is skipped.
resumed = Nexo::Workflow.resume(suspended.id, approved: true)
abort "FAIL: resume status (#{resumed.status.inspect})" unless resumed.status == "done"
abort "FAIL: resume result" unless Nexo::WorkflowRun.find(suspended.id).result["done"] == true
abort "FAIL: resume checkpoint (#{resumed.checkpoint_result("publish").inspect})" unless
  Nexo::WorkflowRun.find(suspended.id).checkpoint_result("publish") == "published doc-9"
puts "SUSPEND_RESUME_OK"

# resume_later enqueues the job carrying the run id + input; :inline runs it now.
again = ApprovalFlow.run(id: 12)
abort "FAIL: second suspend" unless again.status == "suspended"
Nexo::Workflow.resume_later(again.id, {approved: true})
abort "FAIL: resume_later did not finish (#{Nexo::WorkflowRun.find(again.id).status})" unless
  Nexo::WorkflowRun.find(again.id).status == "done"
puts "RESUME_LATER_OK"

# --- R4: artifact / artifact_content read the Spec 7 artifacts json array.
report = Reporter.run(x: 1)
persisted = Nexo::WorkflowRun.find(report.id)
abort "FAIL: artifact_content (#{persisted.artifact_content("digest.md").inspect})" unless
  persisted.artifact_content("digest.md") == "the body"
abort "FAIL: artifact hash (#{persisted.artifact("digest.md").inspect})" unless
  persisted.artifact("digest.md")["name"] == "digest.md"
abort "FAIL: missing artifact returns nil" unless persisted.artifact_content("absent.md").nil?
puts "ARTIFACTS_OK"
