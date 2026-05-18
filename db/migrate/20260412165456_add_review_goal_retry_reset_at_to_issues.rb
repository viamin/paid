# frozen_string_literal: true

class AddReviewGoalRetryResetAtToIssues < ActiveRecord::Migration[8.1]
  class MigrationIssue < ApplicationRecord
    self.table_name = "issues"
  end

  def up
    add_column :issues, :review_goal_retry_reset_at, :datetime

    MigrationIssue.unscoped.in_batches.update_all(review_goal_retry_reset_at: Time.current)
  end

  def down
    safety_assured { remove_column :issues, :review_goal_retry_reset_at }
  end
end
