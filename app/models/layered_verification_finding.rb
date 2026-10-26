# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  belongs_to :originating_audit_run, class_name: "AgentRun"

  validates :cause_signature, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :status, inclusion: { in: STATUSES }
  validates :observed_behavior, :check_limitations, presence: true
  validates :cause_signature, uniqueness: { scope: [ :project_id, :obligation_id, :correspondence_claim_id ] }
  validate :records_share_project

  def defer!(reason:)
    update!(status: "deferred", deferred_reason: reason)
  end

  private

  def records_share_project
    errors.add(:obligation, "must belong to the finding project") if obligation && obligation.project_id != project_id
    errors.add(:originating_audit_run, "must belong to the finding project") if originating_audit_run && originating_audit_run.project_id != project_id
  end
end
