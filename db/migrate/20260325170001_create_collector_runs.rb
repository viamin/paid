# frozen_string_literal: true

class CreateCollectorRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :collector_runs do |t|
      t.bigint :project_version_id, null: false
      t.string :collector_type, limit: 100, null: false
      t.string :status, limit: 50, null: false, default: "pending"
      t.datetime :started_at
      t.datetime :completed_at
      t.integer :duration_ms
      t.integer :artifacts_count, default: 0
      t.text :error_message
      t.string :tool_version, limit: 100
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :collector_runs, [ :project_version_id, :collector_type ], unique: true,
      name: "index_collector_runs_on_version_and_type"
    add_index :collector_runs, :status
    add_foreign_key :collector_runs, :project_versions, on_delete: :cascade
  end
end
