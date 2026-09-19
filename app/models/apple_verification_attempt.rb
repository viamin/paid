# frozen_string_literal: true

# One immutable-source execution of a workflow revision in an Apple worker.
# @spec APPLE-WORKER-005
class AppleVerificationAttempt < ApplicationRecord
  STATES = %w[queued provisioning running succeeded failed cancelled timed_out unavailable].freeze
  TERMINAL_STATES = %w[succeeded failed cancelled timed_out unavailable].freeze
  LIFECYCLE_GATES = AppleVerificationWorkflowRevision::LIFECYCLE_GATES

  belongs_to :account
  belongs_to :project
  belongs_to :agent_run, optional: true
  belongs_to :apple_verification_workflow_revision
  belongs_to :apple_worker_profile
  has_many :apple_verification_waivers, dependent: :restrict_with_exception
  has_many :execution_audit_events, dependent: :nullify
  has_many :execution_resource_ledger_entries, dependent: :nullify

  validates :source_digest, format: { with: /\Asha256:[a-f0-9]{64}\z/ }
  validates :status, inclusion: { in: STATES }
  validates :lifecycle_gate, inclusion: { in: LIFECYCLE_GATES }
  validates :retry_number, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :ownership_matches_workflow
  validate :workflow_is_eligible_for_gate
  validate :profile_matches_workflow
  validate :lifecycle_gate_matches_workflow
  validate :agent_run_matches_project

  def terminal?
    TERMINAL_STATES.include?(status)
  end

  private

  def ownership_matches_workflow
    return unless apple_verification_workflow_revision

    errors.add(:project, "must match the workflow project") if project_id != apple_verification_workflow_revision.project_id
    errors.add(:account, "must match the workflow account") if account_id != apple_verification_workflow_revision.account_id
  end

  def workflow_is_eligible_for_gate
    return unless apple_verification_workflow_revision
    return if apple_verification_workflow_revision.approved? || advisory_draft?

    errors.add(:apple_verification_workflow_revision, "must be approved")
  end

  def advisory_draft?
    apple_verification_workflow_revision.draft? && apple_verification_workflow_revision.lifecycle_gate == "agent_iteration"
  end

  def profile_matches_workflow
    return unless apple_verification_workflow_revision

    errors.add(:apple_worker_profile, "must match the workflow profile") if apple_worker_profile_id != apple_verification_workflow_revision.apple_worker_profile_id
  end

  def lifecycle_gate_matches_workflow
    return unless apple_verification_workflow_revision

    errors.add(:lifecycle_gate, "must match the workflow gate") if lifecycle_gate != apple_verification_workflow_revision.lifecycle_gate
  end

  def agent_run_matches_project
    errors.add(:agent_run, "must match the attempt project") if agent_run && agent_run.project_id != project_id
  end
end
