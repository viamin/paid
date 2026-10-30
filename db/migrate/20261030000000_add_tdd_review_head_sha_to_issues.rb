# frozen_string_literal: true

class AddTddReviewHeadShaToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :tdd_review_head_sha, :string, limit: 40,
      comment: "PR head SHA bound to the latest persisted TDD test-review verdict.", if_not_exists: true
  end
end
