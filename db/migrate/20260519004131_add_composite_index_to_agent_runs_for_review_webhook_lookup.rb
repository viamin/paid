# frozen_string_literal: true

class AddCompositeIndexToAgentRunsForReviewWebhookLookup < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    add_index :agent_runs, [ :project_id, :source_pull_request_number, :status ],
      name: "idx_agent_runs_review_feedback_lookup",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :agent_runs,
      name: "idx_agent_runs_review_feedback_lookup",
      algorithm: :concurrently,
      if_exists: true
  end
end
