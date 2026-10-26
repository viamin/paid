# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :originating_audit_run, class_name: "AgentRun"
  has_many :observations, class_name: "LayeredVerificationFindingObservation", foreign_key: :finding_id,
    dependent: :restrict_with_exception

  validates :correspondence_claim_type, :cause_signature, :source_passages, :observed_behavior, presence: true
  validates :status, inclusion: { in: STATUSES }

  def self.record!(project:, obligation:, audit_run:, correspondence_claim_type:, cause_signature:, attributes:, check_result:)
    transaction do
      finding = lock.where(
        project:,
        obligation:,
        correspondence_claim_type:,
        cause_signature:,
        status: %w[open deferred]
      ).first_or_create!(
        originating_audit_run: audit_run,
        source_passages: attributes.fetch(:source_passages),
        observed_behavior: attributes.fetch(:observed_behavior),
        question: attributes.fetch(:question),
        options: attributes.fetch(:options, {}),
        consequences: attributes.fetch(:consequences, {}),
        limitations: attributes.fetch(:limitations)
      )
      finding.observations.create!(check_result:, observed_at: Time.current)
      finding
    end
  end

  def deferred?
    status == "deferred"
  end
end
