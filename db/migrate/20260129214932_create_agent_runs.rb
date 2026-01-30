# frozen_string_literal: true

class CreateAgentRuns < ActiveRecord::Migration[8.1]
  def change
    create_table :agent_runs do |t|
      # Foreign keys
      t.references :project, null: false, foreign_key: { on_delete: :cascade }
      t.references :issue, null: true, foreign_key: { on_delete: :nullify }

      # Temporal tracking
      t.string :temporal_workflow_id, limit: 255
      t.string :temporal_run_id, limit: 255

      # Agent configuration
      t.string :agent_type, limit: 50, null: false

      # Execution state
      t.string :status, limit: 50, null: false, default: "pending"

      # Git context
      t.string :worktree_path, limit: 500
      t.string :branch_name, limit: 255
      t.string :base_commit_sha, limit: 40
      t.string :result_commit_sha, limit: 40

      # Results
      t.string :pull_request_url, limit: 500
      t.integer :pull_request_number
      t.text :error_message

      # Metrics
      t.integer :iterations, default: 0
      t.integer :duration_seconds
      t.integer :tokens_input, default: 0
      t.integer :tokens_output, default: 0
      t.integer :cost_cents, default: 0

      # Lifecycle timestamps
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps
    end

    add_index :agent_runs, :status
    add_index :agent_runs, :temporal_workflow_id
    add_index :agent_runs, [ :project_id, :status ]
    add_index :agent_runs, :created_at
  end
end
