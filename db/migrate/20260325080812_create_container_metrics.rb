# frozen_string_literal: true

class CreateContainerMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :container_metrics do |t|
      t.bigint :agent_run_id, null: false
      t.string :container_id, limit: 128, null: false
      t.float :cpu_percent, null: false, default: 0.0
      t.bigint :memory_bytes, null: false, default: 0
      t.bigint :memory_limit_bytes, null: false, default: 0
      t.float :memory_percent, null: false, default: 0.0
      t.integer :pids_count, default: 0
      t.datetime :recorded_at, null: false

      t.timestamps
    end

    add_index :container_metrics, [ :agent_run_id, :recorded_at ], name: "index_container_metrics_on_run_and_recorded"
    add_index :container_metrics, :container_id
    add_index :container_metrics, :recorded_at
    add_foreign_key :container_metrics, :agent_runs, on_delete: :cascade
  end
end
