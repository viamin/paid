# frozen_string_literal: true

class BackfillNullReviewGoalRetryResetAtOnIssues < ActiveRecord::Migration[8.1]
  class MigrationIssue < ApplicationRecord
    self.table_name = "issues"
  end

  def up
    reset_at = Time.current
    MigrationIssue.unscoped
      .where(is_pull_request: true, pr_review_phase: "restarted")
      .where(review_goal_retry_reset_at: nil)
      .in_batches
      .update_all(review_goal_retry_reset_at: reset_at)
  end

  def down; end
end
