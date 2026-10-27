# frozen_string_literal: true

# Records the operator's intent-validation decision for a reopened issue, so
# the Inbox can offer the supported work continuation instead of a generic
# enhancement retry (#4640). The decision is bound to the issue revision the
# operator reviewed, so a later edit to the scope invalidates it.
#
# @spec MANUAL-REVIEW-RECOVERY-002
class AddReopenReviewDecisionToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :reopen_review_decision, :string,
      comment: "Operator intent-validation decision for a reopened issue " \
               "(intent_valid or intent_superseded). Blank while the reopen " \
               "review is still awaiting a decision."
    add_column :issues, :reopen_review_reason, :text,
      comment: "Operator rationale recorded with the reopen-review decision."
    add_column :issues, :reopen_review_decided_at, :datetime,
      comment: "When the reopen-review intent-validation decision was recorded."
    add_column :issues, :reopen_review_decided_by_id, :bigint,
      comment: "Operator (users.id) who recorded the reopen-review decision."
    add_column :issues, :reopen_review_revision, :string,
      limit: 64,
      comment: "Digest of the issue scope (title and body) the reopen-review " \
               "decision was validated against."
    add_index :issues, :reopen_review_decided_by_id
  end
end
