# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :originating_audit_run, class_name: "AgentRun"
  has_many :observations, class_name: "LayeredVerificationFindingObservation", foreign_key: :finding_id,
    dependent: :destroy, inverse_of: :finding

  validates :cause_signature, :observed_behavior, :limitations, :question, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :project_matches_obligation
  validate :claim_matches_obligation, if: -> { correspondence_claim.present? }

  def self.record!(project:, obligation:, correspondence_claim:, audit_run:, cause_signature:, check_result:, **attributes)
    claim_type = correspondence_claim&.claim_type
    finding = find_or_create_by!(project:, obligation:, correspondence_claim_type: claim_type, cause_signature:) do |record|
      record.correspondence_claim = correspondence_claim
      record.originating_audit_run = audit_run
      record.assign_attributes(attributes)
    end
    finding.observations.create!(check_result:, agent_run: audit_run, provenance: { "audit_run_id" => audit_run.id })
    finding
  end

  private

  def project_matches_obligation
    return if obligation.blank? || obligation.project_id == project_id

    errors.add(:obligation, "must belong to the same project")
  end

  def claim_matches_obligation
    return if correspondence_claim.obligation_id == obligation_id

    errors.add(:correspondence_claim, "must belong to the finding obligation")
  end
end
