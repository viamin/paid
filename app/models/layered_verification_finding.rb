# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATUSES = %w[unresolved deferred resolved].freeze

  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :originating_audit_run, class_name: "AgentRun"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  has_many :observations, class_name: "LayeredVerificationFindingObservation", foreign_key: :finding_id, dependent: :destroy

  validates :cause_signature, :status, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :run_belongs_to_obligation_project

  def self.record!(obligation:, audit_run:, check_result:, cause_signature:, correspondence_claim: nil, details: {})
    transaction do
      finding = where(status: "unresolved").find_or_create_by!(obligation:, correspondence_claim:, cause_signature:) do |record|
        record.originating_audit_run = audit_run
        record.details = details
      end
      finding.observations.find_or_create_by!(check_result:, audit_run:)
      finding
    end
  end

  private

  def run_belongs_to_obligation_project
    return if originating_audit_run&.project_id == obligation&.project_id

    errors.add(:originating_audit_run, "must belong to the obligation project")
  end
end
