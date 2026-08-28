# frozen_string_literal: true

class AddOwnerReviewRequestedShaToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :owner_review_requested_sha, :string,
      limit: 40,
      if_not_exists: true,
      comment: "PR HEAD commit SHA the last owner re-review request was issued for. Prevents re-requesting review from the owner on every poll cycle once auto-merge is blocked only by a stale owner approval for the same commit."
  end
end
