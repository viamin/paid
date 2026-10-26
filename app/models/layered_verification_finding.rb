# frozen_string_literal: true

# An Inbox-visible discrepancy. Acknowledgment and deferral retain it as an
# unresolved record; only fresh supporting evidence may resolve it.
# @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
class LayeredVerificationFinding < ApplicationRecord
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :agent_run, optional: true

  validates :correspondence_claim_type, inclusion: { in: LayeredVerificationCorrespondenceClaim::CLAIM_TYPES }
  validates :cause_signature, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :status, inclusion: { in: STATUSES }
  validates :observed_behavior, :limitations, presence: true
  validate :project_matches_obligation

  def self.record!(obligation:, correspondence_claim_type:, cause_signature:, source_passages:, observed_behavior:, limitations:, observation:, agent_run: nil, decision_options: [])
    transaction do
      finding = lock.where(
        project: obligation.project, obligation:, correspondence_claim_type:, cause_signature:, status: %w[open deferred]
      ).first_or_initialize
      finding.assign_attributes(
        agent_run:, source_passages: Array(source_passages), observed_behavior:, limitations:, decision_options: Array(decision_options)
      )
      finding.observations = Array(finding.observations) + [ observation ]
      finding.save!
      finding
    end
  end

  private

  def project_matches_obligation
    return unless obligation && project_id != obligation.project_id

    errors.add(:project, "must match the obligation project")
  end
end
