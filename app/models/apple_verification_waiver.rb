# frozen_string_literal: true

# A one-attempt administrator waiver; it cannot alter future verification.
# @spec APPLE-WORKER-006
class AppleVerificationWaiver < ApplicationRecord
  LIFECYCLE_GATES = AppleVerificationWorkflowRevision::LIFECYCLE_GATES

  belongs_to :account
  belongs_to :project
  belongs_to :apple_verification_attempt
  belongs_to :apple_verification_workflow_revision
  belongs_to :created_by, class_name: "User"

  validates :source_digest, format: { with: /\Asha256:[a-f0-9]{64}\z/ }
  validates :lifecycle_gate, inclusion: { in: LIFECYCLE_GATES }
  validates :reason, presence: true
  validates :expires_at, presence: true
  validate :ownership_matches_attempt
  validate :binding_matches_attempt
  validate :creator_matches_account

  def active?
    expires_at.future?
  end

  private

  def ownership_matches_attempt
    return unless apple_verification_attempt

    errors.add(:project, "must match the attempt project") if project_id != apple_verification_attempt.project_id
    errors.add(:account, "must match the attempt account") if account_id != apple_verification_attempt.account_id
  end

  def binding_matches_attempt
    return unless apple_verification_attempt

    errors.add(:apple_verification_workflow_revision, "must match the attempt workflow") if apple_verification_workflow_revision_id != apple_verification_attempt.apple_verification_workflow_revision_id
    errors.add(:source_digest, "must match the attempt source") if source_digest != apple_verification_attempt.source_digest
    errors.add(:lifecycle_gate, "must match the attempt gate") if lifecycle_gate != apple_verification_attempt.lifecycle_gate
  end

  def creator_matches_account
    errors.add(:created_by, "must belong to the waiver account") if created_by && created_by.account_id != account_id
  end
end
