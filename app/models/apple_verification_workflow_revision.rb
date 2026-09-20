# frozen_string_literal: true

# @spec APPLE-VERIFY-002
class AppleVerificationWorkflowRevision < ApplicationRecord
  class InvalidTransitionError < StandardError; end

  STATES = %w[draft approved superseded disabled].freeze
  LIFECYCLE_GATES = %w[agent_iteration completion_verification pull_request_verification].freeze
  COMPARISON_ATTRIBUTES = {
    profile_name: "Profile name",
    source_digest: "Source digest",
    referenced_files: "Referenced files",
    worker_constraints: "Worker constraints",
    checks: "Required checks",
    lifecycle_gate: "Lifecycle gate",
    state: "State"
  }.freeze
  belongs_to :project
  belongs_to :approved_by, class_name: "User", optional: true
  has_many :attempts, class_name: "AppleVerificationAttempt", foreign_key: :workflow_revision_id, dependent: :restrict_with_exception
  scope :approved, -> { where(state: "approved") }
  validates :profile_name, :source_digest, presence: true
  validates :state, inclusion: { in: STATES }
  validates :lifecycle_gate, inclusion: { in: LIFECYCLE_GATES }, allow_nil: true

  def draft? = state == "draft"
  def approved? = state == "approved"
  def disabled? = state == "disabled"

  # @spec APPLE-VERIFY-005
  def differences_from(other)
    COMPARISON_ATTRIBUTES.filter_map do |attribute, label|
      next if public_send(attribute) == other.public_send(attribute)

      [ label, { revision: public_send(attribute), comparison: other.public_send(attribute) } ]
    end.to_h
  end

  def approve!(user)
    # Lock the project, not just this row: two draft revisions under the same
    # project could otherwise each see no approved revision and both end up
    # approved.
    project.with_lock do
      reload
      raise InvalidTransitionError, "only draft revisions can be approved" unless draft?

      project.apple_verification_workflow_revisions.approved.where.not(id:).update_all(state: "superseded")
      update!(state: "approved", approved_by: user, approved_at: Time.current)
    end
  end
end
