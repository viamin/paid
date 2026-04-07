# frozen_string_literal: true

class AddDraftReviewColumnsToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :count_toward_draft_review_round, :boolean, default: false, null: false, if_not_exists: true
    add_column :agent_runs, :expected_draft_review_count, :integer, if_not_exists: true
  end
end
