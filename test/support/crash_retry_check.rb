# frozen_string_literal: true

# Driven by test/workflow_crash_retry_test.rb as two separate processes over one
# Disk run store: `run` starts a workflow that finishes one checkpoint and then
# hangs (the test kills it with SIGKILL); `retry` is the next process, which
# sweeps the dead run and runs it again.
require "nexo"

mode, dir = ARGV
Nexo.configure { |config| config.run_store = Nexo::RunStore::Disk.new(dir: File.join(dir, "runs")) }

class CrashFlow < Nexo::Workflow
  def call(payload)
    first = checkpoint("first") do
      File.write(File.join(payload[:dir], "first.log"), "ran\n", mode: "a")
      "first-done"
    end
    second = checkpoint("second") do
      sleep 120 if ENV["CRASH_HANG"] == "1"
      "second-done"
    end
    {first: first, second: second}
  end
end

case mode
when "run"
  CrashFlow.run(dir: dir)
when "retry"
  swept = Nexo::Workflow.reconcile_interrupted!
  run = Nexo::RunStore.default.all.first
  retried = CrashFlow.retry(run.id)
  puts "swept=#{swept} was=#{run.status} now=#{retried.status} result=#{retried.result.inspect}"
end
