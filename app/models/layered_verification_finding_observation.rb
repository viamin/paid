# frozen_string_literal: true

class LayeredVerificationFindingObservation < ApplicationRecord
  belongs_to :finding, class_name: "LayeredVerificationFinding", inverse_of: :observations
  belongs_to :check_result, class_name: "LayeredVerificationCheckResult"
  belongs_to :agent_run

  validate :evidence_belongs_to_finding_obligation

  private

  def evidence_belongs_to_finding_obligation
    return if finding.blank? || check_result.blank? || check_result.obligation_id == finding.obligation_id

    errors.add(:check_result, "must belong to the finding obligation")
  end
end
