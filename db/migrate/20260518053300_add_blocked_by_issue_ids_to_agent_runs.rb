# frozen_string_literal: true

class AddBlockedByIssueIdsToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :blocked_by_issue_ids, :bigint, array: true, default: [],
      comment: "IDs of issues/PRs that block the created issue from being picked up for work."
  end
end
