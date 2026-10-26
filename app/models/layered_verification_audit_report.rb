# frozen_string_literal: true

class LayeredVerificationAuditReport < ApplicationRecord
  # @spec LAYERED-VERIFY-024
  belongs_to :agent_run

  validates :agent_run, uniqueness: true
  validate :audit_run_goal

  private

  def audit_run_goal
    return if agent_run.blank? || agent_run.goal == "layered_verification_audit"

    errors.add(:agent_run, "must be a layered-verification audit")
  end
end
