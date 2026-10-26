# frozen_string_literal: true

class LayeredVerificationFindingObservation < ApplicationRecord
  belongs_to :finding, class_name: "LayeredVerificationFinding", inverse_of: :observations
  belongs_to :check_result, class_name: "LayeredVerificationCheckResult"
  belongs_to :agent_run

  validate :records_belong_to_finding_project

  private

  def records_belong_to_finding_project
    return unless finding && (check_result.obligation.project_id != finding.project_id || agent_run.project_id != finding.project_id)

    errors.add(:base, "observation records must belong to the finding project")
  end
end
