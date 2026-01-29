# frozen_string_literal: true

class CreateAgentRunLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_run_logs do |t|
      t.references :agent_run, null: false, foreign_key: { on_delete: :cascade }

      # Log classification
      t.string :log_type, limit: 50, null: false

      # Content
      t.text :content, null: false

      # Optional metadata
      t.jsonb :metadata

      t.datetime :created_at, null: false
    end

    add_index :agent_run_logs, [ :agent_run_id, :log_type ]
    add_index :agent_run_logs, :created_at
  end
end
