# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :audit_run, class_name: "AgentRun"
  has_many :observations, class_name: "LayeredVerificationFindingObservation", foreign_key: :finding_id,
    dependent: :restrict_with_exception, inverse_of: :finding

  validates :status, inclusion: { in: STATUSES }
  validates :correspondence_claim_type, :cause_signature, :source_passages, :observed_behavior,
    :limitations, :question, presence: true
  validates :cause_signature, uniqueness: { scope: %i[project_id obligation_id correspondence_claim_type], conditions: -> { where(status: "open") } }
  validate :associated_records_share_project

  def self.record_observation!(project:, obligation:, correspondence_claim: nil, audit_run:, correspondence_claim_type:, cause_signature:, check_result: nil, **attributes)
    transaction do
      evidence = attributes.delete(:evidence) || {}
      finding = lock.where(project:, obligation:, correspondence_claim_type:, cause_signature:, status: "open").first_or_create! do |record|
        record.assign_attributes(attributes.merge(correspondence_claim:, audit_run:))
      end
      finding.observations.create!(audit_run:, check_result:, evidence:)
      finding
    end
  end

  private

  def associated_records_share_project
    errors.add(:obligation, "must belong to the finding project") if obligation && obligation.project_id != project_id
    errors.add(:audit_run, "must belong to the finding project") if audit_run && audit_run.project_id != project_id
  end
end
