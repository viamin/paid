# frozen_string_literal: true

# A reassessment is new evidence about a preserved producer artifact. It never
# changes the producer run's terminal state or its original assessment.
# @spec AUTO-MERGE-011
class ConflictRepairScopeEvidence < ApplicationRecord
  STATUSES = %w[approved rejected unavailable].freeze

  belongs_to :agent_run
  belongs_to :account
  belongs_to :project
  belongs_to :issue
  belongs_to :requested_by, class_name: "User", optional: true

  validates :pre_run_sha, :integration_base_sha, :result_sha, :provider_head_sha, :explanation, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :scope_matches_producer

  def self.current_for(agent_run:, head_sha:, integration_base_sha:)
    where(agent_run:, result_sha: head_sha, provider_head_sha: head_sha, integration_base_sha:)
      .order(created_at: :desc, id: :desc).first
  end

  private

  def scope_matches_producer
    errors.add(:account, "must match producer") unless account_id == agent_run&.project&.account_id
    errors.add(:project, "must match producer") unless project_id == agent_run&.project_id
    errors.add(:issue, "must match producer") unless issue_id == agent_run&.issue_id
  end
end
