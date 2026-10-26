# frozen_string_literal: true

# Records WHY an issue is parked in `manual_review` as structured provenance,
# so the Inbox can route recovery to the action that matches the cause
# (reopen review, unresolved dependency, scanner verification, enhancement)
# instead of always restarting an enhancement run.
#
# `manual_review_reason` stays free-form operator-facing prose; this column is
# the machine-readable cause the classifier and the recovery service read.
# Legacy rows keep a NULL cause and are classified from the durable records
# that identify a cause (see Issues::ManualReviewCause).
#
# The reopen-review columns record the operator's intent-validation decision
# for a reopened issue. The decision is bound to one evidence revision
# (`reopen_review_validation_digest`), so a decision made against stale
# evidence does not silently authorize new work.
#
# @spec OPERATOR-INBOX-002N @spec ISSUE-REOPEN-REVIEW-005
class AddManualReviewCauseToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :manual_review_cause, :string,
      comment: "Machine-readable cause of the current manual_review hold " \
               "(reopen_review, dependency_blocked, scanner_verification, " \
               "enhancement). NULL for rows parked before this column existed."
    add_column :issues, :reopen_review_validated_at, :datetime,
      comment: "When an operator validated the current intent of a reopened issue."
    add_column :issues, :reopen_review_decision, :string,
      comment: "Recorded reopen-intent decision (continue or no_further_work)."
    add_column :issues, :reopen_review_reason, :text,
      comment: "Operator-authored rationale for the recorded reopen-intent decision."
    add_column :issues, :reopen_review_validation_digest, :string,
      comment: "Evidence revision the reopen-intent decision was bound to; " \
               "a newer revision makes the recorded decision stale."
    add_column :issues, :reopen_review_validated_by_id, :bigint,
      comment: "Operator (users.id) who recorded the reopen-intent decision."
  end
end
