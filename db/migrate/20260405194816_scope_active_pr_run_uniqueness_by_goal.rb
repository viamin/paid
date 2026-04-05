class ScopeActivePrRunUniquenessByGoal < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ACTIVE_PR_RUN_WHERE = "source_pull_request_number IS NOT NULL AND status IN ('queued', 'pending', 'running', 'paused')"

  def up
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_pr", algorithm: :concurrently, if_exists: true

    add_index :agent_runs, [ :project_id, :source_pull_request_number, :goal ],
      unique: true,
      where: ACTIVE_PR_RUN_WHERE,
      name: "idx_agent_runs_unique_active_pr",
      algorithm: :concurrently
  end

  def down
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_pr", algorithm: :concurrently, if_exists: true

    add_index :agent_runs, [ :project_id, :source_pull_request_number ],
      unique: true,
      where: ACTIVE_PR_RUN_WHERE,
      name: "idx_agent_runs_unique_active_pr",
      algorithm: :concurrently
  end
end
