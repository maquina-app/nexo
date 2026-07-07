# frozen_string_literal: true

# Additive migration for apps installed before Spec 13 (fresh installs get the
# column from create_nexo_workflow_runs directly). Portable json object column,
# default {} — it holds one entry per completed checkpoint plus the reserved
# "__suspend__" suspend metadata. The migration version is resolved from the host
# app's ActiveRecord rather than hardcoded, so it tracks whatever Rails is installed.
class AddStateToNexoWorkflowRuns < ActiveRecord::Migration[ActiveRecord::Migration.current_version]
  # Adds the +state+ json object column (default +{}+) to +nexo_workflow_runs+.
  def change
    add_column :nexo_workflow_runs, :state, :json, null: false, default: {}
  end
end
