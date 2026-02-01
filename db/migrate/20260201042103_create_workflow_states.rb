# frozen_string_literal: true

class CreateWorkflowStates < ActiveRecord::Migration[8.0]
  def change
    create_table :workflow_states do |t|
      t.string :temporal_workflow_id, null: false
      t.string :temporal_run_id
      t.references :project, foreign_key: true

      t.string :workflow_type, limit: 100, null: false
      t.string :status, limit: 50, null: false, default: "running"

      t.jsonb :input_data
      t.jsonb :result_data
      t.text :error_message

      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :workflow_states, :temporal_workflow_id, unique: true
    add_index :workflow_states, :status
  end
end
