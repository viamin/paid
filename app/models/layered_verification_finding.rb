# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :agent_run, optional: true

  validates :correspondence_claim_type, inclusion: { in: LayeredVerificationCorrespondenceClaim::CLAIM_TYPES + [ "none" ] }
  validates :state, inclusion: { in: STATES }
  validates :obligation_external_identity, :cause_signature, :observed_behavior, :check_limitations, :question, presence: true
  validates :cause_signature, uniqueness: { scope: [ :project_id, :obligation_external_identity, :correspondence_claim_type ], conditions: -> { where.not(state: "resolved") } }
  validate :obligation_belongs_to_project

  scope :actionable, -> { where.not(state: "resolved") }

  def defer!(reason:)
    update!(state: "deferred", deferred_at: Time.current, deferral_reason: reason)
  end

  private

  def obligation_belongs_to_project
    return if obligation.blank? || obligation.project_id == project_id

    errors.add(:obligation, "must belong to the same project")
  end
end
