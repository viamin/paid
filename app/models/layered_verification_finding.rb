# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-015 @spec LAYERED-VERIFY-016 @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :agent_run, optional: true

  validates :obligation_external_identity, :correspondence_claim_type, :cause_signature, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :cause_signature, format: { with: /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/ }
  validates :cause_signature, uniqueness: { scope: %i[project_id obligation_external_identity correspondence_claim_type] }
  validate :obligation_belongs_to_project

  def self.record!(obligation:, correspondence_claim_type:, cause_signature:, observation:, **attributes)
    identity = { project: obligation.project, obligation_external_identity: obligation.external_identity, correspondence_claim_type:, cause_signature: }
    finding = find_or_initialize_by(identity)
    finding.assign_attributes(attributes.merge(obligation:))
    finding.observations = Array(finding.observations) + [ observation.deep_stringify_keys ]
    finding.save!
    finding
  rescue ActiveRecord::RecordNotUnique
    retry
  end

  def resolved? = status == "resolved"

  private

  def obligation_belongs_to_project
    return if obligation.blank? || obligation.project_id == project_id

    errors.add(:obligation, "must belong to the same project")
  end
end
