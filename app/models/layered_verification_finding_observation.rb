# frozen_string_literal: true

class LayeredVerificationFindingObservation < ApplicationRecord
  belongs_to :finding, class_name: "LayeredVerificationFinding"
  belongs_to :check_result, class_name: "LayeredVerificationCheckResult"
  belongs_to :audit_run, class_name: "AgentRun"

  validate :observation_matches_finding

  private

  def observation_matches_finding
    return if finding&.obligation_id == check_result&.obligation_id && finding&.obligation&.project_id == audit_run&.project_id

    errors.add(:check_result, "must belong to the finding obligation and audit project")
  end
end
