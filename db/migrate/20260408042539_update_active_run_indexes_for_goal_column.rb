# frozen_string_literal: true

class UpdateActiveRunIndexesForGoalColumn < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_issue", algorithm: :concurrently, if_exists: true
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_pr", algorithm: :concurrently, if_exists: true

    add_index :agent_runs, [ :project_id, :issue_id, :goal ],
      unique: true,
      where: "issue_id IS NOT NULL AND status IN ('queued', 'pending', 'running', 'paused')",
      name: "idx_agent_runs_unique_active_issue",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :agent_runs, [ :project_id, :source_pull_request_number, :goal ],
      unique: true,
      where: "source_pull_request_number IS NOT NULL AND status IN ('queued', 'pending', 'running', 'paused')",
      name: "idx_agent_runs_unique_active_pr",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_issue", algorithm: :concurrently, if_exists: true
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_pr", algorithm: :concurrently, if_exists: true

    add_index :agent_runs, [ :project_id, :issue_id ],
      unique: true,
      where: "issue_id IS NOT NULL AND status IN ('queued', 'pending', 'running', 'paused')",
      name: "idx_agent_runs_unique_active_issue",
      algorithm: :concurrently,
      if_not_exists: true

    add_index :agent_runs, [ :project_id, :source_pull_request_number ],
      unique: true,
      where: "source_pull_request_number IS NOT NULL AND status IN ('queued', 'pending', 'running', 'paused')",
      name: "idx_agent_runs_unique_active_pr",
      algorithm: :concurrently,
      if_not_exists: true
  end
end
