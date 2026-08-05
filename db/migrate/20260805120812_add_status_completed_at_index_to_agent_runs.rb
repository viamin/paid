# frozen_string_literal: true

class AddStatusCompletedAtIndexToAgentRuns < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :agent_runs, [ :status, :completed_at ], name: "index_agent_runs_on_status_completed_at",
      if_not_exists: true, algorithm: :concurrently
  end

  def down
    remove_index :agent_runs, name: "index_agent_runs_on_status_completed_at", if_exists: true,
      algorithm: :concurrently
  end
end
