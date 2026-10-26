# frozen_string_literal: true

# An unresolved, scoped discrepancy. Observations are append-only so repeated
# audits add evidence without hiding the original conflict.
class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :agent_run, optional: true

  validates :cause_signature, :obligation_external_identity, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :cause_signature, uniqueness: { scope: [ :project_id, :obligation_external_identity, :correspondence_claim_type ] }

  def self.record!(obligation:, correspondence_claim:, cause_signature:, observation:, agent_run:)
    attributes = {
      project: obligation.project,
      obligation:,
      correspondence_claim:,
      obligation_external_identity: obligation.external_identity,
      correspondence_claim_type: correspondence_claim&.claim_type || "direct",
      cause_signature:
    }
    finding = where(attributes.slice(:project, :obligation_external_identity, :correspondence_claim_type, :cause_signature))
      .where.not(status: "resolved").first_or_initialize(attributes)
    finding.observations = Array(finding.observations) + [ observation.merge("agent_run_id" => agent_run.id, "recorded_at" => Time.current.iso8601) ]
    finding.agent_run = agent_run
    finding.save!
    finding
  end
end
