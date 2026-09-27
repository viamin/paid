# frozen_string_literal: true

# Durable scanner evidence for one merged remediation. A merged PR is never a
# resolution; only this record's verified_fixed state is one. # @spec EAGER-QUEUE-013
class CodeScanningRemediationAttempt < ApplicationRecord
  STATUSES = %w[awaiting_verification verified_fixed verification_failed verification_blocked].freeze

  belongs_to :issue
  belongs_to :agent_run, optional: true

  validates :pull_request_number, presence: true, numericality: { greater_than: 0 }
  validates :merge_commit_sha, presence: true
  validates :merged_at, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :blocking_automation, -> { where(status: %w[awaiting_verification verification_failed verification_blocked]) }
end
