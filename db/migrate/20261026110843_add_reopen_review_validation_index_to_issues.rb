# frozen_string_literal: true

# Concurrent index for the reopen-review validation lookups added by
# AddManualReviewCauseToIssues.
# @spec OPERATOR-INBOX-002N @spec ISSUE-REOPEN-REVIEW-005
class AddReopenReviewValidationIndexToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ISSUES_INDEX = "index_issues_on_reopen_review_validated_by_id".freeze

  def up
    return unless column_exists?(:issues, :reopen_review_validated_by_id)
    return if index_exists?(:issues, :reopen_review_validated_by_id, name: ISSUES_INDEX)

    add_index :issues, :reopen_review_validated_by_id,
      name: ISSUES_INDEX,
      where: "reopen_review_validated_by_id IS NOT NULL",
      algorithm: :concurrently
  end

  def down
    remove_index :issues, name: ISSUES_INDEX, if_exists: true, algorithm: :concurrently
  end
end
