# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-017
  STATUSES = %w[unresolved deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :agent_run
  has_many :observations, class_name: "LayeredVerificationFindingObservation", foreign_key: :finding_id,
    dependent: :destroy, inverse_of: :finding

  validates :correspondence_claim_type, :cause_signature, :observed_behavior, :check_limitations, :question, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :records_share_project

  scope :actionable, -> { where(status: "unresolved") }

  def self.record!(attributes:, check_result:, agent_run:, evidence: {})
    identity = attributes.slice(:project_id, :obligation_id, :correspondence_claim_type, :cause_signature)
    transaction do
      finding = actionable.lock.find_or_create_by!(identity) do |record|
        record.assign_attributes(attributes.merge(agent_run:))
      end
      finding.observations.find_or_create_by!(check_result:) { |observation| observation.assign_attributes(agent_run:, evidence:) }
      finding
    end
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  private

  def records_share_project
    return unless obligation && obligation.project_id != project_id

    errors.add(:obligation, "must belong to the same project")
  end
end
