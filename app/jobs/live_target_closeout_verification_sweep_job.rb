# frozen_string_literal: true

# Bounded recovery for missed environment signals. The current signal is read
# once for the sweep and every execution rechecks it before collecting data.
class LiveTargetCloseoutVerificationSweepJob < ApplicationJob
  queue_as :maintenance

  PROJECT_BATCH_SIZE = 20
  MAPPING_BATCH_SIZE = 100

  # @spec STAGED-CLOSEOUT-ADOPTION-012
  def perform(after_project_id: nil, through_project_id: nil, project_id: nil, after_mapping_id: nil)
    target_revision = TrustedMeasurements::DeploymentSignal.current
    return if target_revision.blank?
    return reconcile(Project.active.find_by(id: project_id), target_revision, after_mapping_id:) if project_id

    through_project_id ||= Project.active.maximum(:id)
    return unless through_project_id

    projects = Project.active.where("id > ? AND id <= ?", after_project_id.to_i, through_project_id).order(:id).limit(PROJECT_BATCH_SIZE)
    projects.each { |project| reconcile(project, target_revision) }
    self.class.perform_later(after_project_id: projects.last.id, through_project_id:) if projects.size == PROJECT_BATCH_SIZE
  end

  private

  def reconcile(project, target_revision, after_mapping_id: nil)
    return unless project

    mapping_ids = project.staged_closeout_mappings.approved.where(stage: "live_environment")
      .where("id > ?", after_mapping_id.to_i).order(:id).limit(MAPPING_BATCH_SIZE).pluck(:id)
    CloseoutVerifications::AdmitLiveTarget.call(project:, target_revision:, mapping_ids:) if mapping_ids.any?
    return unless mapping_ids.size == MAPPING_BATCH_SIZE

    self.class.perform_later(project_id: project.id, after_mapping_id: mapping_ids.last)
  end
end
