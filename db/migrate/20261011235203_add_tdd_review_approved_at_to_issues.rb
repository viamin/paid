# frozen_string_literal: true

class AddTddReviewApprovedAtToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :tdd_review_approved_at, :datetime,
      comment: "Time the local TDD test-review gate was most recently approved in ignored label mode."
  end
end
