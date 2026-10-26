# frozen_string_literal: true

class LayeredVerificationFindingObservation < ApplicationRecord
  belongs_to :finding, class_name: "LayeredVerificationFinding"
  belongs_to :check_result, class_name: "LayeredVerificationCheckResult", optional: true
  belongs_to :agent_run

  validate :agent_run_belongs_to_finding_project

  private

  def agent_run_belongs_to_finding_project
    return if agent_run&.project_id == finding&.project_id

    errors.add(:agent_run, "must belong to the finding project")
  end
end
