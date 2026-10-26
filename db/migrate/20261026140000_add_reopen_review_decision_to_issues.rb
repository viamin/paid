# frozen_string_literal: true

# @spec ISSUE-REOPEN-REVIEW-005
class AddReopenReviewDecisionToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :reopen_review_decision, :string
    add_column :issues, :reopen_review_decision_reason, :text
    add_column :issues, :reopen_review_decision_revision, :string
    add_column :issues, :reopen_review_decided_at, :datetime
    add_reference :issues, :reopen_review_decided_by, foreign_key: { to_table: :users }
  end
end
