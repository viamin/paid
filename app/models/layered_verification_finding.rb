# frozen_string_literal: true

# @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-017
class LayeredVerificationFinding < ApplicationRecord
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :originating_audit_run, class_name: "AgentRun"
  has_many :observations, class_name: "LayeredVerificationFindingObservation", foreign_key: :finding_id,
    dependent: :destroy, inverse_of: :finding

  validates :cause_signature, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :status, inclusion: { in: STATUSES }
  validate :records_belong_to_project

  def self.record!(audit_run:, obligation:, check_result:, cause_signature:, detail:, correspondence_claim: nil)
    finding = find_or_create_by!(
      project: audit_run.project, obligation:, correspondence_claim:, cause_signature:
    ) do |record|
      record.originating_audit_run = audit_run
      record.detail = detail
    end
    finding.observations.create!(check_result:, agent_run: audit_run, detail:)
    finding
  end

  private

  def records_belong_to_project
    errors.add(:obligation, "must belong to the same project") if obligation && obligation.project_id != project_id
    errors.add(:originating_audit_run, "must belong to the same project") if originating_audit_run && originating_audit_run.project_id != project_id
  end
end
