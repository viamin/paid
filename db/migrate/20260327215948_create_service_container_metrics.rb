class CreateServiceContainerMetrics < ActiveRecord::Migration[8.1]
  def change
    create_table :service_container_metrics do |t|
      t.references :service_container, null: false, foreign_key: { on_delete: :cascade }
      t.string :container_id, limit: 128, null: false
      t.float :cpu_percent, default: 0.0, null: false
      t.bigint :memory_bytes, default: 0, null: false
      t.bigint :memory_limit_bytes, default: 0, null: false
      t.float :memory_percent, default: 0.0, null: false
      t.integer :pids_count
      t.datetime :recorded_at, null: false

      t.timestamps
    end

    add_index :service_container_metrics,
      [ :service_container_id, :recorded_at ],
      name: "index_service_container_metrics_on_container_and_recorded"
    add_index :service_container_metrics, :container_id
    add_index :service_container_metrics, :recorded_at
  end
end
