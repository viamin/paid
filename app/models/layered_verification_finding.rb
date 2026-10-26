# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  has_many :observations, class_name: "LayeredVerificationFindingObservation", foreign_key: :finding_id,
    dependent: :restrict_with_exception

  validates :correspondence_claim_type, :cause_signature, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :obligation_belongs_to_project

  def self.record!(project:, obligation:, correspondence_claim: nil, correspondence_claim_type:, cause_signature:, evidence:, revision:, agent_run: nil, detail: {})
    transaction do
      finding = lock.where(project:, obligation:, correspondence_claim_type:, cause_signature:, status: "open").first_or_create!(
        correspondence_claim:, detail:
      )
      finding.observations.create!(agent_run:, evidence:, revision:)
      finding
    end
  end

  private

  def obligation_belongs_to_project
    return if obligation.blank? || obligation.project_id == project_id

    errors.add(:obligation, "must belong to the same project")
  end
end
