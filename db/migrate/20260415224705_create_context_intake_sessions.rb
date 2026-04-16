class CreateContextIntakeSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :context_intake_sessions do |t|
      t.references :project, null: false, foreign_key: true
      t.references :started_by, null: false, foreign_key: { to_table: :users }
      t.string :status, limit: 50, null: false, default: "in_progress"
      t.string :schema_version, limit: 20, null: false, default: "1.0"
      t.integer :current_step, default: 0
      t.datetime :completed_at
      t.datetime :stale_at
      t.jsonb :metadata, default: {}

      t.timestamps
    end

    add_index :context_intake_sessions, [:project_id, :status]
    add_index :context_intake_sessions, [:project_id, :created_at],
      order: { created_at: :desc }
  end
end
