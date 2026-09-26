# frozen_string_literal: true

# One immutable-source execution of a workflow revision in an Apple worker.
# @spec APPLE-WORKER-005
class AppleVerificationAttempt < ApplicationRecord
  STATES = %w[queued provisioning running succeeded failed cancelled timed_out unavailable].freeze
  TERMINAL_STATES = %w[succeeded failed cancelled timed_out unavailable].freeze
  LIFECYCLE_GATES = AppleVerificationWorkflowRevision::LIFECYCLE_GATES
  # @spec APPLE-ATTEMPT-009
  FAILURE_CLASSIFICATIONS = %w[project_configuration compile_or_link test_assertion launch_or_ui_flow required_capture network_policy unsupported_capability capacity_or_quota worker_infrastructure cancellation_or_timeout].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :agent_run, optional: true
  belongs_to :apple_verification_workflow_revision
  belongs_to :apple_worker_profile
  belongs_to :retry_of_attempt, class_name: "AppleVerificationAttempt", optional: true
  # @spec APPLE-VERIFY-006
  has_one :retry_attempt,
    class_name: "AppleVerificationAttempt",
    foreign_key: :retry_of_attempt_id,
    dependent: :destroy,
    inverse_of: :retry_of_attempt
  has_many :apple_verification_waivers, dependent: :restrict_with_exception
  has_many :apple_verification_artifacts, dependent: :destroy
  has_many :execution_audit_events, dependent: :nullify
  has_many :execution_resource_ledger_entries, dependent: :nullify

  validates :source_digest, format: { with: /\Asha256:[a-f0-9]{64}\z/ }
  validates :status, inclusion: { in: STATES }
  validates :lifecycle_gate, inclusion: { in: LIFECYCLE_GATES }
  validates :retry_number, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :failure_classification, inclusion: { in: FAILURE_CLASSIFICATIONS }, allow_nil: true
  validate :ownership_matches_workflow
  validate :workflow_is_eligible_for_gate
  validate :profile_matches_workflow
  validate :profile_is_not_revoked
  validate :lifecycle_gate_matches_workflow
  validate :agent_run_matches_project
  validate :execution_binding_is_immutable, on: :update
  after_update_commit :complete_withheld_run, if: :completed_completion_verification?

  def terminal?
    TERMINAL_STATES.include?(status)
  end

  def cancellable?
    !terminal?
  end

  def failed?
    status == "failed"
  end

  def retained_vm?
    execution_resource_ledger_entries.any? { |resource| resource.resource_kind == "verification_vm" && resource.status.in?(%w[active cleanup_failed orphaned]) }
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

  def profile_is_not_revoked
    return unless apple_worker_profile&.revoked?

    errors.add(:apple_worker_profile, "must not be revoked")
  end

  def lifecycle_gate_matches_workflow
    return unless apple_verification_workflow_revision

    errors.add(:lifecycle_gate, "must match the workflow gate") if lifecycle_gate != apple_verification_workflow_revision.lifecycle_gate
  end

  def agent_run_matches_project
    errors.add(:agent_run, "must match the attempt project") if agent_run && agent_run.project_id != project_id
  end

  # A completion-verification attempt can unblock a run after its agent
  # workflow has already returned. Re-invoke completion only after the
  # attempt's success is committed, so the gate observes the final state.
  # @spec APPLE-ATTEMPT-013
  def complete_withheld_run
    AppleVerificationAttempts::CompleteWithheldRun.call(agent_run: agent_run)
  end

  def completed_completion_verification?
    saved_change_to_status? && status == "succeeded" && lifecycle_gate == "completion_verification" && agent_run_id.present?
  end

  def execution_binding_is_immutable
    return unless execution_binding_changed?

    errors.add(:base, "attempt execution binding is immutable")
  end

  def execution_binding_changed?
    will_save_change_to_account_id? || will_save_change_to_project_id? || will_save_change_to_agent_run_id? ||
      will_save_change_to_apple_verification_workflow_revision_id? || will_save_change_to_apple_worker_profile_id? ||
      will_save_change_to_source_digest? || will_save_change_to_commit_sha? || will_save_change_to_lifecycle_gate? ||
      will_save_change_to_requested_capture? || will_save_change_to_retry_number? || will_save_change_to_retry_of_attempt_id?
  end
end
