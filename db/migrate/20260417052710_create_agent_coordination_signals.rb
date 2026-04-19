# frozen_string_literal: true

class CreateAgentCoordinationSignals < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_coordination_signals do |t|
      t.references :source_agent_run, null: false, foreign_key: { to_table: :agent_runs }
      t.references :target_agent_run, null: true, foreign_key: { to_table: :agent_runs }
      t.string :parent_workflow_id, limit: 255, null: false
      t.string :signal_type, limit: 50, null: false
      t.jsonb :payload, default: {}, null: false
      t.datetime :created_at, null: false
    end

    add_index :agent_coordination_signals, :parent_workflow_id
    add_index :agent_coordination_signals, [ :parent_workflow_id, :signal_type ],
      name: "idx_coordination_signals_workflow_type"
    add_index :agent_coordination_signals, [ :target_agent_run_id, :signal_type ],
      name: "idx_coordination_signals_target_type"
  end
end
