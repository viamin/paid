# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-017
  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :agent_run, optional: true

  validates :cause_signature, :correspondence_claim_type, presence: true
  validates :cause_signature, uniqueness: { scope: [ :project_id, :obligation_id, :correspondence_claim_type ] }

  scope :open, -> { where(resolved_at: nil) }

  def open? = resolved_at.nil?

  def self.record!(obligation:, correspondence_claim: nil, agent_run: nil, cause_signature:, attributes: {})
    finding = find_or_initialize_by(
      project: obligation.project, obligation:, correspondence_claim_type: correspondence_claim&.claim_type || "unmapped",
      cause_signature:
    )
    observation = attributes.delete(:observation) || attributes.delete("observation") || {}
    finding.assign_attributes(attributes.merge(correspondence_claim:, agent_run:))
    finding.observations = Array(finding.observations) + [ observation ]
    finding.save!
    finding
  end
end
