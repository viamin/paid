# frozen_string_literal: true

class LayeredVerificationFindingObservation < ApplicationRecord
  belongs_to :finding, class_name: "LayeredVerificationFinding", inverse_of: :observations
  belongs_to :check_result, class_name: "LayeredVerificationCheckResult"
  belongs_to :agent_run

  validate :check_result_belongs_to_finding_obligation
  validate :agent_run_belongs_to_finding_project

  private

  def check_result_belongs_to_finding_obligation
    return if check_result.blank? || finding.blank? || check_result.obligation_id == finding.obligation_id

    errors.add(:check_result, "must belong to the finding obligation")
  end

  def agent_run_belongs_to_finding_project
    return if agent_run.blank? || finding.blank? || agent_run.project_id == finding.project_id

    errors.add(:agent_run, "must belong to the finding project")
  end
end
