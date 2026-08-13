# frozen_string_literal: true

class CreateAgentRunAnomalies < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_run_anomalies do |t|
      t.references :agent_run, null: false, foreign_key: true
      t.references :project, null: false, foreign_key: true
      t.string :anomaly_type, limit: 50, null: false
      t.string :severity, limit: 20, null: false
      t.string :metric_name, limit: 50, null: false
      t.float :metric_value, null: false
      t.float :baseline_mean, null: false
      t.float :baseline_standard_deviation, null: false
      t.float :deviation_factor, null: false
      t.text :message

      t.timestamps
    end

    add_index :agent_run_anomalies, [ :project_id, :created_at ]
    add_index :agent_run_anomalies, :anomaly_type
  end
end
