# frozen_string_literal: true

class AddReviewPostedAtToAgentRuns < ActiveRecord::Migration[8.1]
  def change
    add_column :agent_runs, :review_posted_at, :datetime, null: true
  end
end
