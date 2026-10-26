# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-017
  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :agent_run, optional: true
  has_many :observations, class_name: "LayeredVerificationFindingObservation", dependent: :restrict_with_exception

  validates :obligation_external_identity, :cause_signature, :status, presence: true
  validates :status, inclusion: { in: %w[open deferred resolved] }
  validates :cause_signature, uniqueness: { scope: %i[project_id obligation_external_identity correspondence_claim_type] }

  def self.record!(project:, obligation:, correspondence_claim:, cause_signature:, attributes:, observation:)
    finding = lock.where(project:, obligation_external_identity: obligation.external_identity,
      correspondence_claim_type: correspondence_claim&.claim_type, cause_signature:).first_or_create! do |record|
      record.obligation = obligation
      record.correspondence_claim = correspondence_claim
      record.assign_attributes(attributes.merge(status: "open"))
    end
    finding.observations.create!(observation)
    finding
  end
end
