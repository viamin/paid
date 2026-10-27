# frozen_string_literal: true

# An operator's recorded verdict on a parked issue, bound to the exact
# revision of the issue's intent that the verdict was made against (#4640).
#
# The binding is what makes the verdict meaningful: an issue's intent can
# change after the verdict, and a stale verdict must not silently authorize
# work against a revision nobody reviewed. The unique index on
# (issue_id, revision_digest) makes a repeated submit idempotent instead of
# writing a second verdict for the same revision.
#
# @spec MANUAL-REVIEW-RECOVERY-002
class ManualReviewDecision < ApplicationRecord
  REOPEN_REVIEW = "reopen_review"
  SCANNER_RECURRENCE = "scanner_recurrence"

  # The intent behind a reopened issue either still holds or has moved on; the
  # reason records which and why.
  INTENT_VALID = "intent_valid"
  INTENT_CHANGED = "intent_changed"
  REMEDIATION_AUTHORIZED = "remediation_authorized"

  CAUSES = [ REOPEN_REVIEW, SCANNER_RECURRENCE ].freeze
  DECISIONS = [ INTENT_VALID, INTENT_CHANGED, REMEDIATION_AUTHORIZED ].freeze

  belongs_to :issue
  belongs_to :project
  belongs_to :actor, class_name: "User"

  validates :cause, inclusion: { in: CAUSES }
  validates :decision, inclusion: { in: DECISIONS }
  validates :reason, presence: true
  validates :revision_digest, presence: true

  scope :for_revision, ->(issue_id, revision_digest) {
    where(issue_id:, revision_digest:)
  }
end
