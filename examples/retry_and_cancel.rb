# frozen_string_literal: true

# Retry a failed run without repeating the work it finished, and cancel a run
# that is waiting. No model, no network.
#
#   ruby -Ilib examples/retry_and_cancel.rb
#
# A run's checkpoints are kept in its state. `Nexo::Workflow.retry` re-enters
# `#call` from the top, and every checkpoint the run completed before it stopped
# returns its stored value instead of running again.
require "nexo"
require "tmpdir"

# Runs have to outlive the failure to be retried, so they go to disk. (Under
# Rails the ActiveRecord store does this; the default in-memory store is for tests.)
Nexo.configure { |c| c.run_store = Nexo::RunStore::Disk.new(dir: Dir.mktmpdir("nexo-runs")) }

class NightlyImport < Nexo::Workflow
  UPSTREAM = {healthy: false} # stands in for a service that is down the first time

  def call(_payload)
    rows = checkpoint(:download) do
      emit(:downloading)
      1_200 # expensive: we want this exactly once
    end

    clean = checkpoint(:clean) do
      emit(:cleaning)
      raise "upstream timed out" unless UPSTREAM[:healthy]

      rows - 37
    end

    checkpoint(:load) { emit(:loading, rows: clean) }
    {loaded: clean}
  end
end

class AwaitingSignoff < Nexo::Workflow
  def call(_payload)
    suspend!(reason: "waiting for the finance sign-off") unless resume_input[:signed]
    {signed: true}
  end
end

if __FILE__ == $PROGRAM_NAME
  store = Nexo::RunStore.default

  # 1) The run fails in its second step. `run` re-raises, as any failure does.
  begin
    NightlyImport.run
  rescue => e
    puts "first pass raised:        #{e.message}"
  end
  failed = store.all.first
  puts "status:                   #{failed.status}"                # => "failed"
  puts "download checkpoint kept: #{failed.state["download"].inspect}"

  # 2) The upstream recovers. Retry the SAME run: :download is not repeated.
  NightlyImport::UPSTREAM[:healthy] = true
  retried = Nexo::Workflow.retry(failed.id)
  puts "status after retry:       #{retried.status}"               # => "done"
  puts "result:                   #{retried.result.inspect}"
  events = retried.events.map { |event| event["type"] }
  puts "events:                   #{events.inspect}"
  puts "downloaded once:          #{events.count("downloading") == 1}"

  # 3) Cancel a run that is waiting. A waiting run is cancelled at once; a
  #    running one is asked to stop and ends "cancelled" at its next checkpoint.
  waiting = AwaitingSignoff.run
  puts "second run:               #{waiting.status} (#{waiting.state["__suspend__"]["reason"]})"
  cancelled = Nexo::Workflow.cancel(waiting.id)
  puts "after cancel:             #{cancelled.status}"             # => "cancelled"

  # A cancelled run is final.
  begin
    Nexo::Workflow.retry(cancelled.id)
  rescue Nexo::Error => e
    puts "retrying it:              #{e.message}"
  end
end
