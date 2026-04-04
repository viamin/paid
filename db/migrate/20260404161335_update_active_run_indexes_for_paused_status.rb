# frozen_string_literal: true

class UpdateActiveRunIndexesForPausedStatus < ActiveRecord::Migration[8.1]
  def up
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_issue"
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_pr"

    add_index :agent_runs, [ :project_id, :issue_id ],
      unique: true,
      where: "issue_id IS NOT NULL AND status IN ('queued', 'pending', 'running', 'paused')",
      name: "idx_agent_runs_unique_active_issue"

    add_index :agent_runs, [ :project_id, :source_pull_request_number ],
      unique: true,
      where: "source_pull_request_number IS NOT NULL AND status IN ('queued', 'pending', 'running', 'paused')",
      name: "idx_agent_runs_unique_active_pr"
  end

  def down
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_issue"
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_pr"

    add_index :agent_runs, [ :project_id, :issue_id ],
      unique: true,
      where: "issue_id IS NOT NULL AND status IN ('queued', 'pending', 'running')",
      name: "idx_agent_runs_unique_active_issue"

    add_index :agent_runs, [ :project_id, :source_pull_request_number ],
      unique: true,
      where: "source_pull_request_number IS NOT NULL AND status IN ('queued', 'pending', 'running')",
      name: "idx_agent_runs_unique_active_pr"
  end
end
