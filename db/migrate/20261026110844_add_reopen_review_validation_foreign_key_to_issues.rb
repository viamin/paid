# frozen_string_literal: true

# The `issues` -> `users` table pair already carries a `reopened_by_id`
# foreign key, so the new column must be named explicitly — a bare
# `add_foreign_key :issues, :users` would resolve the first matching
# constraint and leave the new referential-integrity safeguard unenforced.
# @spec OPERATOR-INBOX-002N @spec ISSUE-REOPEN-REVIEW-005
class AddReopenReviewValidationForeignKeyToIssues < ActiveRecord::Migration[8.1]
  def up
    return unless column_exists?(:issues, :reopen_review_validated_by_id)
    return if foreign_key_exists?(:issues, :users, column: :reopen_review_validated_by_id)

    add_foreign_key :issues, :users, column: :reopen_review_validated_by_id, validate: false
  end

  def down
    remove_foreign_key :issues, column: :reopen_review_validated_by_id if foreign_key_exists?(:issues, column: :reopen_review_validated_by_id)
  end
end
