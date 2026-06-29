# frozen_string_literal: true

namespace :nexo do
  desc "Print the ordered event log for a workflow run: nexo:logs[run_id]"
  task :logs, [:run_id] => :environment do |_, args|
    # The run id is a UUID string — pass it through as-is (no .to_i coercion).
    Nexo::Workflow.logs(args[:run_id]) do |ev|
      puts "[#{ev["at"]}] #{ev["type"].ljust(12)} #{ev["data"].inspect}"
    end
  end
end
