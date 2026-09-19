# frozen_string_literal: true

# @spec APPLE-VERIFY-003
class AppleVerificationAttempt < ApplicationRecord
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
  def waived? = state == "waived"
end
