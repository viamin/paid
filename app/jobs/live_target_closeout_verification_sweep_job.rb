# frozen_string_literal: true

# Bounded recovery for missed environment signals. The current signal is read
# once for the sweep and every execution rechecks it before collecting data.
class LiveTargetCloseoutVerificationSweepJob < ApplicationJob
  queue_as :maintenance

  PROJECT_BATCH_SIZE = 20

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  def perform(after_project_id: nil, through_project_id: nil)
    target_revision = TrustedMeasurements::DeploymentSignal.current
    return if target_revision.blank?

    through_project_id ||= Project.active.maximum(:id)
    return unless through_project_id

    projects = Project.active.where("id > ? AND id <= ?", after_project_id.to_i, through_project_id).order(:id).limit(PROJECT_BATCH_SIZE)
    projects.each { |project| CloseoutVerifications::AdmitLiveTarget.call(project:, target_revision:) }
    self.class.perform_later(after_project_id: projects.last.id, through_project_id:) if projects.size == PROJECT_BATCH_SIZE
  end
end
