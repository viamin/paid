# frozen_string_literal: true

class LayeredVerificationFindingObservation < ApplicationRecord
  belongs_to :finding, class_name: "LayeredVerificationFinding"
  belongs_to :audit_run, class_name: "AgentRun"
  belongs_to :check_result, class_name: "LayeredVerificationCheckResult", optional: true

  validate :audit_run_belongs_to_finding_project

  private

  def audit_run_belongs_to_finding_project
    return unless finding && audit_run && finding.project_id != audit_run.project_id

    errors.add(:audit_run, "must belong to the finding project")
  end
end
