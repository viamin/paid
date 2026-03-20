# frozen_string_literal: true

class CreateAgentRunPhases < ActiveRecord::Migration[8.0]
  def change
    create_table :agent_run_phases do |t|
      t.references :agent_run, null: false, foreign_key: true
      t.string :phase_key, null: false, limit: 100
      t.string :phase_group, null: false, limit: 50
      t.string :status, null: false, limit: 50, default: "completed"
      t.timestamp :started_at, null: false
      t.timestamp :finished_at, null: false
      t.integer :duration_seconds, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :agent_run_phases, [ :agent_run_id, :started_at ]
    add_index :agent_run_phases, [ :phase_group, :started_at ]
    add_index :agent_run_phases, [ :phase_key, :started_at ]
  end
end
