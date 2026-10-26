# frozen_string_literal: true

# One assessment of a queue stall: a delivery handoff that stopped
# progressing, the state revision the assessment was derived from, and the
# outcome of the recovery attempt (#4619).
#
# The (issue, reason code, state digest) triple is unique: an unchanged state
# is assessed once and never recovered twice, while a changed blocker set
# produces a new digest and is assessed again.
# @spec QUEUE-DIAG-005 @spec QUEUE-DIAG-012
class QueueStallAssessment < ApplicationRecord
  include TenantScoped

  REASON_CODES = %w[unseeded_runnable stale_planning_hold unresolved_delivery].freeze
  # `observed` records a state that has not been unchanged long enough to
  # count as a stall yet, so no recovery was attempted for it.
  OUTCOMES = %w[recovered blocked observed skipped failed].freeze

  belongs_to :account
  belongs_to :issue

  validates :reason_code, inclusion: { in: REASON_CODES }
  validates :outcome, inclusion: { in: OUTCOMES }
  validates :state_digest, presence: true
  validates :assessed_at, presence: true
  validates :attempt_count, numericality: { greater_than: 0 }
  validates :issue_id, uniqueness: { scope: %i[reason_code state_digest] }

  scope :for_reason, ->(reason_code) { where(reason_code:) }

  # The most recent assessment for each issue, used to render "last assessed"
  # provenance next to an issue's blockers.
  # @spec QUEUE-DIAG-003
  def self.latest_per_issue(issue_ids)
    return [] if issue_ids.empty?

    where(issue_id: issue_ids).where.not(outcome: "failed").order(assessed_at: :desc, id: :desc).to_a.uniq(&:issue_id)
  end
end
