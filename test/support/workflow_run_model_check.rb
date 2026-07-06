# frozen_string_literal: true

# Exercises the Rails-only Nexo::WorkflowRun model against an in-memory SQLite
# database. Run in a SEPARATE process (see test/workflow_run_model_test.rb):
# loading ActiveRecord into the main offline suite would flip RunStore.default
# to the AR backend for every other test. Prints OK markers the parent asserts
# on, and aborts (non-zero exit) on any mismatch.

require "active_record"

lib = File.expand_path("../../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require "nexo_ai"            # provides Nexo.generate_run_id; Zeitwerk ignores the model
require "nexo/workflow_run"  # ActiveRecord present → the guarded body defines the model

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ":memory:")

# Build the schema by running the real migration template — this also confirms
# the json-column / string-UUID-PK migration is valid against SQLite.
require File.expand_path("../../lib/generators/nexo/workflows/templates/create_nexo_workflow_runs.rb", __dir__)
ActiveRecord::Migration.verbose = false
CreateNexoWorkflowRuns.new.migrate(:up)

# Defaults: status "pending", events [], and a UUID string id assigned by the
# model's before_create (no explicit id passed).
run = Nexo::WorkflowRun.create!(workflow_class: "Demo", payload: {"x" => 1})
abort "FAIL: status default (#{run.status.inspect})" unless run.status == "pending"
abort "FAIL: events default (#{run.events.inspect})" unless run.events == []
abort "FAIL: uuid id (#{run.id.inspect})" unless /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/.match?(run.id)
puts "PENDING_OK"

# push_event + save_events! persists an ordered event array.
run.push_event({"type" => "a", "data" => {}, "at" => "t1"})
run.push_event({"type" => "b", "data" => {}, "at" => "t2"})
run.save_events!
reloaded = Nexo::WorkflowRun.find(run.id)
abort "FAIL: events persisted (#{reloaded.events.inspect})" unless reloaded.events.map { |e| e["type"] } == %w[a b]
puts "EVENTS_OK"

# result/payload round-trip to string keys through the json column.
run.update!(status: "done", result: {foo: "bar"})
abort "FAIL: result string keys (#{Nexo::WorkflowRun.find(run.id).result.inspect})" unless Nexo::WorkflowRun.find(run.id).result == {"foo" => "bar"}
puts "RESULT_STRING_KEYS_OK"

# artifacts default to [] and round-trip string-keyed through the json column,
# with push_artifact/save_artifacts! mirroring the event path (Spec 7).
abort "FAIL: artifacts default (#{run.artifacts.inspect})" unless Nexo::WorkflowRun.find(run.id).artifacts == []
run.push_artifact({"name" => "digest.md", "content" => "body", "at" => "t1"})
run.push_artifact({"name" => "report.md", "content" => "more", "at" => "t2"})
run.save_artifacts!
arts = Nexo::WorkflowRun.find(run.id).artifacts
abort "FAIL: artifacts persisted (#{arts.inspect})" unless arts.map { |a| a["name"] } == %w[digest.md report.md]
abort "FAIL: artifacts string keys (#{arts.first.keys.inspect})" unless arts.first.keys.sort == %w[at content name]
puts "ARTIFACTS_OK"

# state defaults to {} and round-trips string-keyed through the json column, with
# save_state! (touch-free) mirroring the events/artifacts path (Spec 13). Group 0
# VERIFY: confirm string keys survive so checkpoint's store.key?(key) matches Memory.
abort "FAIL: state default (#{Nexo::WorkflowRun.find(run.id).state.inspect})" unless Nexo::WorkflowRun.find(run.id).state == {}
run.state = (run.state || {}).merge("fetch" => "doc-1", "__suspend__" => {"reason" => "wait"})
run.save_state!
st = Nexo::WorkflowRun.find(run.id).state
abort "FAIL: state persisted (#{st.inspect})" unless st["fetch"] == "doc-1"
abort "FAIL: state string keys (#{st.keys.sort.inspect})" unless st.keys.sort == %w[__suspend__ fetch]
abort "FAIL: state key? (checkpoint match)" unless st.key?("fetch")
abort "FAIL: suspend_reader" unless Nexo::WorkflowRun.find(run.id).suspend_reason == "wait"
abort "FAIL: checkpoint_result reader" unless Nexo::WorkflowRun.find(run.id).checkpoint_result("fetch") == "doc-1"
puts "STATE_OK"
