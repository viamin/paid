# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :audit_run, class_name: "AgentRun"
  belongs_to :correspondence_claim, class_name: "LayeredVerificationCorrespondenceClaim", optional: true
  has_many :observations, class_name: "LayeredVerificationFindingObservation", foreign_key: :finding_id,
    dependent: :restrict_with_exception, inverse_of: :finding

  scope :unresolved, -> { where(resolved_at: nil) }

  validates :cause_signature, :observed_behavior, :question, presence: true
  validate :associated_records_belong_to_project

  def defer!(reason:)
    update!(deferred_at: Time.current, deferral_reason: reason)
  end

  private

  def associated_records_belong_to_project
    errors.add(:obligation, "must belong to the same project") if obligation && obligation.project_id != project_id
    errors.add(:audit_run, "must belong to the same project") if audit_run && audit_run.project_id != project_id
    return unless correspondence_claim && correspondence_claim.obligation_id != obligation_id

    errors.add(:correspondence_claim, "must belong to the obligation")
  end
end
