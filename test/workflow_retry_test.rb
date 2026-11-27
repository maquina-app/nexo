# frozen_string_literal: true

require "test_helper"
require "tmpdir"

# Workflow.retry (0.16): a run that failed or was interrupted is run again, and
# the checkpoints it finished before it stopped are not repeated.
class WorkflowRetryTest < Minitest::Test
  class Flaky < Nexo::Workflow
    class << self
      attr_accessor :reads, :fail_digest, :fail_source
    end

    def call(_payload)
      sources = checkpoint_all(
        "mail" => -> { read("mail") },
        "hey" => -> { read("hey") }
      )
      raise "digest failed" if self.class.fail_digest

      {sources: sources.keys.sort}
    end

    def read(name)
      raise "#{name} is down" if self.class.fail_source == name

      self.class.reads << name
      "#{name}.json"
    end
  end

  def setup
    Nexo.reset_config!
    Nexo::RunStore::Memory.reset!
    Flaky.reads = []
    Flaky.fail_digest = false
    Flaky.fail_source = nil
  end

  def teardown = Nexo.reset_config!

  # Runs the block, which fails, and returns the run it left behind.
  def failed_run
    assert_raises(RuntimeError) { yield }
    store = Nexo::RunStore.default
    store.respond_to?(:all) ? store.all.first : Nexo::RunStore::Memory.runs.values.last
  end

  def test_a_retry_does_not_repeat_finished_checkpoints
    Flaky.fail_digest = true
    run = failed_run { Flaky.run }
    assert_equal "failed", run.status
    assert_equal "digest failed", run.error
    assert_equal %w[hey mail], Flaky.reads.sort

    Flaky.fail_digest = false
    retried = Flaky.retry(run.id)

    assert_equal "done", retried.status
    assert_equal run.id, retried.id
    assert_nil retried.error
    assert_equal({"sources" => %w[hey mail]}, retried.result)
    assert_equal %w[hey mail], Flaky.reads.sort, "no source was read a second time"
  end

  def test_a_retry_runs_only_the_step_of_a_batch_that_did_not_finish
    Flaky.fail_source = "hey"
    run = failed_run { Flaky.run }
    assert_equal "failed", run.status
    assert_equal %w[mail], Flaky.reads

    Flaky.fail_source = nil
    retried = Flaky.retry(run.id)

    assert_equal "done", retried.status
    assert_equal %w[mail hey], Flaky.reads, "only the source that failed was read"
  end

  def test_a_retry_that_fails_again_stays_failed_and_can_be_retried_again
    Flaky.fail_digest = true
    run = failed_run { Flaky.run }

    assert_raises(RuntimeError) { Flaky.retry(run.id) }
    assert_equal "failed", Nexo::RunStore.default.find(run.id).status

    Flaky.fail_digest = false
    assert_equal "done", Flaky.retry(run.id).status
  end

  def test_an_interrupted_run_can_be_retried
    Flaky.fail_digest = true
    run = failed_run { Flaky.run }
    run.update!(status: "interrupted")
    Flaky.fail_digest = false

    assert_equal "done", Flaky.retry(run.id).status
  end

  def test_only_failed_or_interrupted_runs_can_be_retried
    done = Flaky.run

    error = assert_raises(Nexo::Error) { Flaky.retry(done.id) }

    assert_match(/cannot be retried \(done\)/, error.message)
  end

  def test_a_retry_works_across_processes_through_the_disk_store
    Dir.mktmpdir do |dir|
      Nexo.config.run_store = Nexo::RunStore::Disk.new(dir: dir)
      Flaky.fail_digest = true
      run = failed_run { Flaky.run }
      Flaky.fail_digest = false
      Flaky.reads = []

      # A second store over the same directory is what a new process would build.
      Nexo.config.run_store = Nexo::RunStore::Disk.new(dir: dir)
      retried = Flaky.retry(run.id)

      assert_equal "done", retried.status
      assert_empty Flaky.reads
      assert_equal "done", Nexo::RunStore::Disk.new(dir: dir).find(run.id).status
    end
  end
end
