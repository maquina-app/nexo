# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# The file-backed run store: the same run shape as Memory, persisted. The point
# of it is durability ACROSS a process, so the load-bearing test forks.
class RunStoreDiskTest < Minitest::Test
  def setup
    @dir = Dir.mktmpdir
    @store = Nexo::RunStore::Disk.new(dir: @dir)
  end

  def teardown
    Nexo.config.run_store = nil
    FileUtils.remove_entry(@dir)
  end

  class Countdown < Nexo::Workflow
    def call(payload)
      checkpoint(:expensive) { {"paid" => payload[:cost]} }
      suspend!(reason: "awaiting input") unless resume_input[:go]
      {"finished" => true}
    end
  end

  # ---- the store contract --------------------------------------------------

  def test_a_created_run_is_on_disk_immediately
    run = @store.create(workflow_class: "X", payload: {"a" => 1})

    assert_path_exists File.join(@dir, "#{run.id}.json")
    assert_equal "pending", @store.find(run.id).status
  end

  def test_a_missing_run_raises_key_error_like_memory
    assert_raises(KeyError) { @store.find("nope") }
  end

  def test_updates_events_artifacts_and_state_all_survive_a_reread
    run = @store.create(workflow_class: "X", payload: {})
    run.update!(status: "running")
    run.push_event({"type" => "started"})
    run.save_events!
    run.push_artifact({"name" => "out.txt", "content" => "hi"})
    run.save_artifacts!
    run.state = {"step" => 42}
    run.save_state!

    fresh = @store.find(run.id)

    assert_equal "running", fresh.status
    assert_equal [{"type" => "started"}], fresh.events
    assert_equal "hi", fresh.artifact_content("out.txt")
    assert_equal 42, fresh.checkpoint_result(:step)
  end

  def test_it_shares_memorys_read_helpers
    run = @store.create(workflow_class: "X", payload: {})
    run.update!(status: "suspended", state: {"__suspend__" => {"reason" => "why"}})

    fresh = @store.find(run.id)

    assert_predicate fresh, :suspended?
    assert_equal "why", fresh.suspend_reason
    refute_predicate fresh, :done?
  end

  def test_claim_for_resume_succeeds_once_and_then_refuses
    run = @store.create(workflow_class: "X", payload: {})
    run.update!(status: "suspended")

    assert @store.claim_for_resume!(@store.find(run.id))
    refute @store.claim_for_resume!(@store.find(run.id)), "a claimed run must not be claimable twice"
  end

  def test_claim_reads_status_from_disk_not_from_a_stale_copy
    run = @store.create(workflow_class: "X", payload: {})
    run.update!(status: "suspended")
    stale = @store.find(run.id)              # says "suspended"
    @store.claim_for_resume!(@store.find(run.id))

    refute @store.claim_for_resume!(stale), "a stale in-memory copy must not win the claim"
  end

  def test_all_lists_runs_and_tolerates_a_corrupt_document
    2.times { @store.create(workflow_class: "X", payload: {}) }
    File.write(File.join(@dir, "garbage.json"), "{not json")

    assert_equal 2, @store.all.size
  end

  def test_a_partial_write_cannot_be_observed
    run = @store.create(workflow_class: "X", payload: {})
    run.update!(status: "running")

    assert_empty Dir.glob(File.join(@dir, "*.tmp")), "the temp file must be renamed, never left behind"
  end

  # ---- selection -----------------------------------------------------------

  def test_the_configured_store_wins_over_the_automatic_choice
    Nexo.config.run_store = @store

    assert_same @store, Nexo::RunStore.default
  end

  def test_memory_is_still_the_default_with_nothing_configured
    assert_instance_of Nexo::RunStore::Memory, Nexo::RunStore.default
  end

  # ---- what it is FOR ------------------------------------------------------

  def test_a_suspended_run_resumes_in_a_second_process_without_repaying_the_checkpoint
    skip "fork is unavailable here" unless Process.respond_to?(:fork)

    dir = @dir
    id = fork_value do
      Nexo.config.run_store = Nexo::RunStore::Disk.new(dir: dir)
      Countdown.run(cost: 99).id
    end

    Nexo.config.run_store = Nexo::RunStore::Disk.new(dir: dir)
    suspended = Nexo::RunStore::Disk.new(dir: dir).find(id)

    assert_equal "suspended", suspended.status, "the first process must have paused, not finished"
    assert_equal({"paid" => 99}, suspended.checkpoint_result(:expensive))

    resumed = Countdown.resume(id, go: true)

    assert_equal "done", resumed.status
    assert_equal({"paid" => 99}, resumed.checkpoint_result(:expensive),
      "the checkpoint must be reused, not re-run")
  end

  private

  # Runs the block in a child process and returns its (String) value.
  def fork_value
    reader, writer = IO.pipe
    pid = fork do
      reader.close
      writer.write(yield)
      writer.close
      exit!(0)
    end
    writer.close
    value = reader.read
    Process.waitpid(pid)
    reader.close
    value
  end
end
