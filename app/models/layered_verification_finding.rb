# frozen_string_literal: true

# @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
class LayeredVerificationFinding < ApplicationRecord
  STATES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :originating_audit_run, class_name: "AgentRun", inverse_of: :layered_verification_findings

  validates :correspondence_claim_type, inclusion: { in: LayeredVerificationCorrespondenceClaim::CLAIM_TYPES }
  validates :cause_signature, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :state, inclusion: { in: STATES }
  validates :observed_behavior, :limitations, :decision_question, presence: true
  validate :records_same_project

  def unresolved? = state.in?(%w[open deferred])

  private

  def records_same_project
    errors.add(:obligation, "must belong to the project") if obligation && obligation.project_id != project_id
    errors.add(:originating_audit_run, "must belong to the project") if originating_audit_run && originating_audit_run.project_id != project_id
  end
end
