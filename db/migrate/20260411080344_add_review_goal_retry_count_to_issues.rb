# frozen_string_literal: true

class AddReviewGoalRetryCountToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :review_goal_retry_count, :integer, default: 0, null: false
  end
end
