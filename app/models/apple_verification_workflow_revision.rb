# frozen_string_literal: true

# @spec APPLE-VERIFY-002
class AppleVerificationWorkflowRevision < ApplicationRecord
  class InvalidTransitionError < StandardError; end

  STATES = %w[draft approved superseded disabled].freeze
  LIFECYCLE_GATES = %w[agent_iteration completion_verification pull_request_verification].freeze
  belongs_to :project
  belongs_to :approved_by, class_name: "User", optional: true
  has_many :attempts, class_name: "AppleVerificationAttempt", foreign_key: :workflow_revision_id, dependent: :restrict_with_exception
  scope :approved, -> { where(state: "approved") }
  validates :profile_name, :source_digest, presence: true
  validates :state, inclusion: { in: STATES }
  validates :lifecycle_gate, inclusion: { in: LIFECYCLE_GATES }, allow_nil: true

  def draft? = state == "draft"
  def approved? = state == "approved"

  def approve!(user)
    with_lock do
      reload
      raise InvalidTransitionError, "only draft revisions can be approved" unless draft?

      project.apple_verification_workflow_revisions.approved.where.not(id:).update_all(state: "superseded")
      update!(state: "approved", approved_by: user, approved_at: Time.current)
    end
  end
end
