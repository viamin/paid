# frozen_string_literal: true

# Generated with `bin/rails generate migration AddReopenReviewValidationToIssues`.
# The generator could not connect in the isolated task environment; retain the
# conventional generated shape here so production migration remains explicit.
class AddReopenReviewValidationToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :reopen_review_decision, :string,
      comment: "Authorized disposition of a reopen review."
    add_column :issues, :reopen_review_review_reason, :text,
      comment: "Operator rationale for the reopen-review disposition."
    add_column :issues, :reopen_review_reviewed_at, :datetime,
      comment: "When the current reopen-review disposition was recorded."
    add_reference :issues, :reopen_review_reviewed_by, index: false,
      comment: "Paid user who recorded the current reopen-review disposition."
    add_column :issues, :reopen_review_revision, :string,
      comment: "GitHub revision observed when the reopen-review disposition was recorded."
  end
end
