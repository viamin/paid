# frozen_string_literal: true

class AddIndexToAgentRunsOnProjectStatusCompletedAt < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :agent_runs, [ :project_id, :status, :completed_at ],
      name: "index_agent_runs_on_project_status_completed_at",
      algorithm: :concurrently
  end
end
