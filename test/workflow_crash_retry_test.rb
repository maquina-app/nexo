# frozen_string_literal: true

require "test_helper"
require "json"
require "open3"
require "rbconfig"
require "tmpdir"

# A real crash, across real processes (0.16): a workflow on the Disk run store
# is killed with SIGKILL after its first checkpoint; a second process sweeps the
# dead run and retries it, and the first checkpoint's work is not done again.
class WorkflowCrashRetryTest < Minitest::Test
  SCRIPT = File.expand_path("support/crash_retry_check.rb", __dir__)

  def test_a_killed_run_is_swept_and_retried_without_repeating_its_checkpoint
    Dir.mktmpdir do |dir|
      pid = Process.spawn({"CRASH_HANG" => "1"}, RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), SCRIPT, "run", dir,
        out: File::NULL, err: File::NULL)
      wait_for_first_checkpoint(dir)
      Process.kill("KILL", pid)
      Process.wait(pid)

      left = JSON.parse(File.read(Dir[File.join(dir, "runs", "*.json")].first))
      assert_equal "running", left["status"], "a killed process cannot mark its own run"
      assert_equal "first-done", left["state"]["first"]

      out, err, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), SCRIPT, "retry", dir)

      assert status.success?, err
      assert_match(/swept=1 was=interrupted now=done/, out)
      assert_match(/"first" ?=> ?"first-done", "second" ?=> ?"second-done"/, out) # Hash#inspect differs before Ruby 3.4
      assert_equal "ran\n", File.read(File.join(dir, "first.log")), "the first checkpoint ran once, in the killed process"
    end
  end

  private

  def wait_for_first_checkpoint(dir)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 30
    loop do
      file = Dir[File.join(dir, "runs", "*.json")].first
      state = file && begin
        JSON.parse(File.read(file))["state"]
      rescue
        nil
      end
      return if state&.key?("first")
      flunk "the first checkpoint was never saved" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.1
    end
  end
end
