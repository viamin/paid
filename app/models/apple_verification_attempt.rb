# frozen_string_literal: true

# @spec APPLE-VERIFY-003
class AppleVerificationAttempt < ApplicationRecord
  class InvalidTransitionError < StandardError; end

  STATES = %w[queued running passed failed cancelled waived].freeze
  FAILURE_CLASSES = %w[project compile test launch capture policy capacity infrastructure timeout cancellation].freeze
  belongs_to :project
  belongs_to :workflow_revision, class_name: "AppleVerificationWorkflowRevision"
  belongs_to :retry_of, class_name: "AppleVerificationAttempt", optional: true
  belongs_to :waived_by, class_name: "User", optional: true
  has_many :retries, class_name: "AppleVerificationAttempt", foreign_key: :retry_of_id, dependent: :nullify
  has_many :artifacts, class_name: "AppleVerificationArtifact", foreign_key: :attempt_id, dependent: :destroy
  validates :state, inclusion: { in: STATES }
  validates :failure_class, inclusion: { in: FAILURE_CLASSES }, allow_nil: true
  validates :waiver_reason, presence: true, if: :waived?

  def queued? = state == "queued"
  def running? = state == "running"
  def passed? = state == "passed"
  def failed? = state == "failed"
  def cancelled? = state == "cancelled"
  def waived? = state == "waived"

  def cancel!
    transition!("only queued or running attempts can be cancelled") do
      AppleVerificationAttempts::Cancel.call(attempt: self) if queued? || running?
    end
  end

  def waive!(user, reason)
    transition!("only failed required attempts can be waived") do
      update!(state: "waived", waived_by: user, waiver_reason: reason) if failed? && required?
    end
  end

  def record_retained_vm_destruction!
    transition!("only failed attempts can have retained VMs destroyed") do
      AppleVerificationAttempts::DestroyRetainedWorker.call(attempt: self) if failed? && retained_vm_destroyed_at.nil?
    end
  end

  def retry!
    raise InvalidTransitionError, "cannot rerun a disabled workflow revision" if workflow_revision.disabled?
    raise InvalidTransitionError, "on-demand verification is not enabled for this project" unless project.apple_verification_on_demand?

    project.apple_verification_attempts.create!(workflow_revision:, retry_of: self, queue_position:).tap do |attempt|
      AppleVerificationAttemptDispatchJob.perform_later(attempt.id)
    end
  end

  def mark_cancelled!
    update!(state: "cancelled", failure_class: "cancellation", cancelled_at: Time.current)
  end

  def mark_retained_vm_destroyed!
    update!(retained_vm_destroyed_at: Time.current)
  end

  def required?
    workflow_revision.approved? && required_checks?
  end

  private

  def transition!(error_message)
    with_lock do
      reload
      raise InvalidTransitionError, error_message unless yield
    end
  end

  def required_checks?
    checks = workflow_revision.checks
    checks.dig("tests", "required") == true || Array(checks["captures"]).any? { _1["required"] == true }
  end
end
