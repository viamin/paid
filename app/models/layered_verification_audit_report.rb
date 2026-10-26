# frozen_string_literal: true

class LayeredVerificationAuditReport < ApplicationRecord
  # @spec LAYERED-VERIFY-024
  belongs_to :agent_run

  validates :agent_run_id, uniqueness: true
  validate :audit_run

  private

  def audit_run
    errors.add(:agent_run, "must be a layered-verification audit") unless agent_run&.goal == "layered_verification_audit"
  end
end
