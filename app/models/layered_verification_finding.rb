# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-017
  STATES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  has_many :observations, class_name: "LayeredVerificationFindingObservation", foreign_key: :finding_id, dependent: :destroy

  validates :correspondence_claim_type, :cause_signature, presence: true
  validates :state, inclusion: { in: STATES }
  validates :cause_signature, uniqueness: { scope: [ :project_id, :obligation_id, :correspondence_claim_type ] }

  def self.record!(project:, obligation:, correspondence_claim_type:, cause_signature:, observation:)
    finding = find_or_create_by!(
      project:, obligation:, correspondence_claim_type:, cause_signature:
    ) { |record| record.state = "open" }
    finding.observations.create!(observation)
    finding
  end
end
