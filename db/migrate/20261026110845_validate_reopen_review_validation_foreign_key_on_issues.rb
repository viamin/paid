# frozen_string_literal: true

# Validates the reopen-review validation foreign key added (validate: false)
# by AddReopenReviewValidationForeignKeyToIssues. The column is named
# explicitly because the `issues` -> `users` table pair already carries a
# `reopened_by_id` foreign key.
# @spec OPERATOR-INBOX-002N @spec ISSUE-REOPEN-REVIEW-005
class ValidateReopenReviewValidationForeignKeyOnIssues < ActiveRecord::Migration[8.1]
  def up
    return unless foreign_key_exists?(:issues, :users, column: :reopen_review_validated_by_id)

    validate_foreign_key :issues, :users, column: :reopen_review_validated_by_id
  end

  def down
  end
end
