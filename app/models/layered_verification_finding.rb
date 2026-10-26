# frozen_string_literal: true

class LayeredVerificationFinding < ApplicationRecord
  # @spec LAYERED-VERIFY-017
  STATUSES = %w[open deferred resolved].freeze

  belongs_to :project
  belongs_to :obligation, class_name: "LayeredVerificationObligation"
  belongs_to :agent_run

  validates :correspondence_claim_type, :cause_signature, presence: true
  validates :status, inclusion: { in: STATUSES }
  validate :records_share_project

  private

  def records_share_project
    return unless project && (obligation.project_id != project_id || agent_run.project_id != project_id)

    errors.add(:project, "must match the obligation and audit run project")
  end
end
