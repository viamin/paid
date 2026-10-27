# frozen_string_literal: true

# Records why an issue is parked in `manual_review` so the operator Inbox can
# route recovery by cause instead of always restarting enhancement (#4640).
#
# The producers of a park write the cause they know exactly; rows parked
# before this column keep a NULL cause, and the classifier derives those from
# the provenance that already exists (reopen-review reason, preserved
# questions, dependency edges, scanner evidence, partial-completion
# assessment) instead of guessing from the reason's prose.
#
# @spec MANUAL-REVIEW-RECOVERY-001
class AddManualReviewCauseToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :manual_review_cause, :string,
      comment: "Why the issue is parked in manual_review: reopen_review, enhancement, " \
               "dependency_wait, scanner_recurrence, or partial_closeout. NULL for rows " \
               "parked before this column existed."
  end
end
