# frozen_string_literal: true

# Digest-bound approval record for a repository Apple verification workflow.
# @spec APPLE-WORKER-004
class AppleVerificationWorkflowRevision < ApplicationRecord
  STATES = %w[draft approved superseded disabled].freeze
  LIFECYCLE_GATES = %w[agent_iteration completion_verification pull_request_verification].freeze

  belongs_to :account
  belongs_to :project
  belongs_to :apple_worker_profile
  belongs_to :approved_by, class_name: "User", optional: true
  has_many :apple_verification_attempts, dependent: :restrict_with_exception
  has_many :apple_verification_waivers, dependent: :restrict_with_exception

  scope :approved, -> { where(status: "approved") }

  validates :revision, numericality: { only_integer: true, greater_than: 0 }, uniqueness: { scope: :project_id }
  validates :content_digest, format: { with: /\Asha256:[a-f0-9]{64}\z/ }
  validates :status, inclusion: { in: STATES }
  validates :lifecycle_gate, inclusion: { in: LIFECYCLE_GATES }
  validate :account_matches_project
  validate :profile_matches_account
  validate :approval_fields_match_state
  validate :approver_is_project_administrator
  validate :approval_requires_active_profile
  validate :approval_binding_is_immutable, on: :update

  def draft?
    status == "draft"
  end

  def approved?
    status == "approved"
  end

  def superseded?
    status == "superseded"
  end

  def disabled?
    status == "disabled"
  end

  def approve!(actor:)
    project.with_lock do
      reload
      raise ArgumentError, "only a draft revision can be approved" unless draft?
      raise ArgumentError, "approver must be a project administrator" unless actor&.has_role?(:project_admin, project)
      raise ArgumentError, "workflow profile must be active" unless apple_worker_profile.active?

      project.apple_verification_workflow_revisions.approved.where.not(id:).find_each(&:supersede!)
      update!(status: "approved", approved_by: actor, approved_at: Time.current)
    end
  end

  def supersede!
    return self if status == "superseded"

    update!(status: "superseded")
    self
  end

  def disable!
    return self if status == "disabled"

    update!(status: "disabled")
    self
  end

  private

  def account_matches_project
    errors.add(:account, "must match the project's account") if project && account_id != project.account_id
  end

  def profile_matches_account
    errors.add(:apple_worker_profile, "must belong to the workflow account") if apple_worker_profile && account_id != apple_worker_profile.account_id
  end

  def approval_fields_match_state
    return unless draft? || approved?
    return if approved? ? approved_by_id.present? && approved_at.present? : approved_by_id.blank? && approved_at.blank?

    errors.add(:base, "approval actor and timestamp are required only for approved revisions")
  end

  def approver_is_project_administrator
    return unless approved? && approved_by && project
    return if approved_by.has_role?(:project_admin, project)

    errors.add(:approved_by, "must be a project administrator")
  end

  def approval_requires_active_profile
    return unless approved? && apple_worker_profile
    return if apple_worker_profile.active?

    errors.add(:apple_worker_profile, "must be active to approve")
  end

  def approval_binding_is_immutable
    return unless approved? || status_in_database == "approved"
    return unless will_save_change_to_project_id? || will_save_change_to_content_digest? || will_save_change_to_verification_files? || will_save_change_to_apple_worker_profile_id? || will_save_change_to_lifecycle_gate? || will_save_change_to_required_checks? || will_save_change_to_advisory_checks?

    errors.add(:base, "approved workflow binding is immutable")
  end
end
