# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATUSES = %w[unresolved deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :agent_run
  has_many :observations, class_name: "LayeredVerificationFindingObservation", dependent: :restrict_with_exception

  validates :status, inclusion: { in: STATUSES }
  validates :cause_signature, :observed_behavior, :question, presence: true
  validates :correspondence_claim_type, inclusion: { in: LayeredVerificationCorrespondenceClaim::CLAIM_TYPES + [ "none" ] }
  validate :records_belong_to_obligation_project

  def defer!(reason:)
    update!(status: "deferred", deferred_reason: reason)
  end

  private

  def records_belong_to_obligation_project
    errors.add(:obligation, "must belong to the same project") unless obligation&.project_id == project_id
    errors.add(:agent_run, "must belong to the same project") unless agent_run&.project_id == project_id
  end
end
