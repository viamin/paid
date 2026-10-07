# frozen_string_literal: true

# Durable scanner evidence for one merged remediation. A merged PR is never a
# resolution; only this record's verified_fixed state is one.
# @spec EAGER-QUEUE-013
# @spec EAGER-QUEUE-014
# @spec EAGER-QUEUE-015
class CodeScanningRemediationAttempt < ApplicationRecord
  STATUSES = %w[awaiting_verification verified_fixed verification_failed verification_blocked].freeze
  RETRYABLE_STATUSES = %w[awaiting_verification verification_blocked].freeze

  belongs_to :issue
  belongs_to :agent_run, optional: true

  validates :pull_request_number, presence: true, numericality: { greater_than: 0 }
  validates :merge_commit_sha, presence: true
  validates :merged_at, presence: true
  validates :status, inclusion: { in: STATUSES }

  # `verification_failed` is the durable terminal block — scanner confirmed
  # the merged fix did not close the finding, and the source issue has moved
  # to manual review. `awaiting_verification` and `verification_blocked` are
  # both retryable: the verifier revisits them on every relevant scan,
  # re-applying the same evidence rules EAGER-QUEUE-013 requires (#4152).
  scope :blocking_automation, -> { where(status: %w[verification_failed]) }
  scope :retryable_block, -> { where(status: RETRYABLE_STATUSES) }

  # Single attempt per issue that governs auto-pick eligibility. A new
  # merged PR records a fresh attempt; the prior attempt's terminal status
  # SHALL NOT keep the issue out of auto-pick once superseded by a later
  # attempt's `verified_fixed` outcome (EAGER-QUEUE-015). The duplicate-PR
  # prevention guards remain the durable stop against a second concurrent
  # fix PR (EAGER-QUEUE-009).
  scope :latest_per_issue, -> { where(id: latest_ids_per_issue) }

  def self.latest_ids_per_issue
    group(:issue_id).maximum(:id).values
  end
end
