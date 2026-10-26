# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :originating_audit_run, class_name: "AgentRun"
  has_many :observations, class_name: "LayeredVerificationFindingObservation", foreign_key: :finding_id,
    dependent: :restrict_with_exception, inverse_of: :finding

  validates :correspondence_claim_type, :cause_signature, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :cause_signature, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :cause_signature, uniqueness: { scope: [ :project_id, :obligation_id, :correspondence_claim_type ] }
  validate :obligation_belongs_to_project

  private

  def obligation_belongs_to_project
    return if obligation.blank? || obligation.project_id == project_id

    errors.add(:obligation, "must belong to the finding project")
  end
end
