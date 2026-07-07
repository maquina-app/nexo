# frozen_string_literal: true

require "test_helper"

# Storage seam, Memory backend — pure logic, no DB. With no Rails loaded
# RunStore.default selects Memory, which is the path the offline suite exercises.
class RunStoreTest < Minitest::Test
  def setup
    @store = Nexo::RunStore::Memory.new
  end

  def test_default_selects_the_memory_backend_without_rails
    assert_instance_of Nexo::RunStore::Memory, Nexo::RunStore.default
  end

  def test_create_returns_a_pending_run_with_a_uuid_string_id
    run = @store.create(workflow_class: "Demo", payload: {"x" => 1})

    assert_equal "pending", run.status
    assert_equal "Demo", run.workflow_class
    assert_equal({"x" => 1}, run.payload)
    assert_equal [], run.events
    assert_kind_of String, run.id
    assert_match(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/, run.id)
  end

  def test_find_retrieves_a_created_run_by_id
    run = @store.create(workflow_class: "Demo", payload: {})

    assert_same run, @store.find(run.id)
  end

  def test_push_event_appends_to_the_ordered_event_log
    run = @store.create(workflow_class: "Demo", payload: {})
    run.push_event({"type" => "a"})
    run.push_event({"type" => "b"})

    assert_equal %w[a b], run.events.map { |ev| ev["type"] }
  end

  def test_update_assigns_attributes_in_place
    run = @store.create(workflow_class: "Demo", payload: {})
    run.update!(status: "done", result: {"ok" => true})

    assert_equal "done", run.status
    assert_equal({"ok" => true}, run.result)
  end

  # The Memory run exposes the same read helpers as the AR model, so host code
  # written against a finished run behaves identically in plain Ruby and Rails.
  def test_memory_run_mirrors_the_ar_read_helpers
    run = @store.create(workflow_class: "Demo", payload: {})

    run.update!(status: "suspended", state: {"__suspend__" => {"reason" => "wait"}, "fetch" => 7})
    assert run.suspended?
    refute run.done?
    assert_equal "wait", run.suspend_reason
    assert_equal 7, run.checkpoint_result(:fetch)

    run.update!(status: "done")
    run.push_artifact({"name" => "report.md", "content" => "hello"})
    assert run.done?
    assert_equal({"name" => "report.md", "content" => "hello"}, run.artifact("report.md"))
    assert_equal "hello", run.artifact_content("report.md")
    assert_nil run.artifact_content("absent.md")
  end
end
