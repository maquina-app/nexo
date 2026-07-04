# frozen_string_literal: true

# Additive migration for apps installed before Spec 7 (fresh installs get the
# column from create_nexo_workflow_runs directly). Portable json column, default
# [], matching the events column shape.
class AddArtifactsToNexoWorkflowRuns < ActiveRecord::Migration[8.0]
  def change
    add_column :nexo_workflow_runs, :artifacts, :json, null: false, default: []
  end
end
