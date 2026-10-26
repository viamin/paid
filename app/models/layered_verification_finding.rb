# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :agent_run
  has_many :observations, class_name: "LayeredVerificationFindingObservation", foreign_key: :finding_id,
    dependent: :destroy, inverse_of: :finding

  validates :correspondence_claim_type, :cause_signature, :source_passages, :observed_behavior, :limitations, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :cause_signature, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :cause_signature, uniqueness: { scope: [ :project_id, :obligation_id, :correspondence_claim_type ] }
  validate :obligation_belongs_to_project

  def defer!(reason:)
    update!(status: "deferred", deferred_at: Time.current, deferral_reason: reason.presence || raise(ArgumentError, "deferral reason is required"))
  end

  private

  def obligation_belongs_to_project
    errors.add(:obligation, "must belong to the same project") if obligation && obligation.project_id != project_id
  end
end
