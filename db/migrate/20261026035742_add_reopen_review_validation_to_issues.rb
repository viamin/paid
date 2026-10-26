# frozen_string_literal: true

class AddReopenReviewValidationToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :reopen_review_validated_at, :datetime, comment: "When an operator last validated a reopened issue's current intent."
    add_reference :issues, :reopen_review_validated_by, index: false, comment: "Operator who validated the current reopen intent."
    add_column :issues, :reopen_review_validation_reason, :text, comment: "Operator's reason for resuming work after reopen review."
    add_column :issues, :reopen_review_validation_revision, :string, comment: "GitHub updated-at revision bound to the reopen validation."
  end
end
