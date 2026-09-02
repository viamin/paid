# frozen_string_literal: true

# Gives manual_review a durable entry marker so the inbox can report how long
# an issue has actually been stopped instead of falling back to `updated_at`,
# a shared touch timestamp bumped by unrelated writes (label syncs, etc.).
# Mirrors `pr_escalation_started_at`, added for the same reason on the PR side.
#
# @spec ISSUE-ENHANCEMENT-012
class AddManualReviewFieldsToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :manual_review_started_at, :datetime,
      comment: "Timestamp when this issue entered paid_state: manual_review. " \
               "Falls back to updated_at for legacy rows predating this column."
    add_column :issues, :manual_review_reason, :text,
      comment: "Why automation stopped and parked this issue in manual_review, " \
               "surfaced in the operator inbox."
  end
end
