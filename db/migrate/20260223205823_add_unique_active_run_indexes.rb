# frozen_string_literal: true

class AddUniqueActiveRunIndexes < ActiveRecord::Migration[8.0]
  def change
    # Prevent duplicate queued/pending/running runs for the same project+issue.
    add_index :agent_runs, [ :project_id, :issue_id ],
      unique: true,
      where: "issue_id IS NOT NULL AND status IN ('queued', 'pending', 'running')",
      name: "idx_agent_runs_unique_active_issue"

    # Prevent duplicate queued/pending/running runs for the same project+PR number.
    add_index :agent_runs, [ :project_id, :source_pull_request_number ],
      unique: true,
      where: "source_pull_request_number IS NOT NULL AND status IN ('queued', 'pending', 'running')",
      name: "idx_agent_runs_unique_active_pr"
  end
end
