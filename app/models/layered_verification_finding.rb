# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :agent_run
  has_many :observations, class_name: "LayeredVerificationFindingObservation",
    foreign_key: :finding_id, dependent: :restrict_with_exception, inverse_of: :finding

  validates :correspondence_claim_type, inclusion: { in: LayeredVerificationCorrespondenceClaim::CLAIM_TYPES }
  validates :cause_signature, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :status, inclusion: { in: STATUSES }
  validates :observed_behavior, :question, presence: true
  validates :cause_signature, uniqueness: { scope: [ :project_id, :obligation_id, :correspondence_claim_type ] }
  validate :obligation_belongs_to_project

  def defer!(reason:)
    update!(status: "deferred", deferred_reason: reason)
  end

  private

  def obligation_belongs_to_project
    return if obligation.blank? || obligation.project_id == project_id

    errors.add(:obligation, "must belong to the same project")
  end
end
