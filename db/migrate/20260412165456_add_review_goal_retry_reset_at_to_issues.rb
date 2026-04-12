# frozen_string_literal: true

class AddReviewGoalRetryResetAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :review_goal_retry_reset_at, :datetime
  end
end
