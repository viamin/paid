# frozen_string_literal: true

class CreateAgentRunPhases < ActiveRecord::Migration[8.1]
  def up
    create_table :agent_run_phases do |t|
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }
      t.string :phase_key, null: false, limit: 100
      t.string :phase_group, null: false, limit: 50
      t.string :status, null: false, limit: 50, default: "completed"
      t.datetime :started_at, null: false
      t.datetime :finished_at, null: false
      t.integer :duration_seconds, null: false, default: 0
      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :agent_run_phases, [ :agent_run_id, :started_at ]
    add_index :agent_run_phases, [ :phase_group, :started_at ]
    add_index :agent_run_phases, [ :phase_key, :started_at ]
    add_check_constraint :agent_run_phases, "finished_at >= started_at", name: "agent_run_phases_finished_at_after_started_at"
    add_check_constraint :agent_run_phases, "duration_seconds >= 0", name: "agent_run_phases_duration_seconds_non_negative"
  end

  def down
    remove_check_constraint :agent_run_phases, name: "agent_run_phases_finished_at_after_started_at", if_exists: true
    remove_check_constraint :agent_run_phases, name: "agent_run_phases_duration_seconds_non_negative", if_exists: true
    drop_table :agent_run_phases
  end
end
