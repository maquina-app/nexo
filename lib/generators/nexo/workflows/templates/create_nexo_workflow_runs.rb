# frozen_string_literal: true

# json columns are used everywhere (not jsonb) so the schema is portable across
# SQLite and PostgreSQL without an adapter-aware path. The primary key is the
# UUID string id assigned by Nexo::WorkflowRun before_create.
class CreateNexoWorkflowRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :nexo_workflow_runs, id: false do |t|
      t.string :id, null: false, primary_key: true
      t.string :workflow_class, null: false
      t.string :status, null: false, default: "pending" # pending|running|done|failed|suspended
      t.json :payload, null: false, default: {}
      t.json :result
      t.text :error
      t.json :events, null: false, default: []
      t.json :artifacts, null: false, default: []
      t.json :state, null: false, default: {} # checkpoints + suspend metadata (Spec 13)
      t.timestamps
    end
    add_index :nexo_workflow_runs, :workflow_class
    add_index :nexo_workflow_runs, :status
  end
end
