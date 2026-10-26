# frozen_string_literal: true

module Projects
  # Submits operator evidence through the same per-occurrence reconciliation
  # service used by built-in evidence producers. The controller owns only
  # project scoping and authorization.
  # @spec PARTIAL-CLOSEOUT-030
  class CloseoutEvidenceSubmissionsController < ApplicationController
    def create
      project = policy_scope(Project).find(params[:project_id])
      authorize project, :run_agent?
      notification = project.account.notifications.where(source: PartialCloseouts::PREREQUISITE_NOTIFICATION_SOURCE,
        subject_type: "Issue").find(params[:notification_id])
      return head :not_found unless notification.subject.project_id == project.id

      result = PartialCloseouts::SubmitPrerequisiteEvidence.call(notification:, actor: current_user,
        prerequisite_id: params[:prerequisite_id].to_s, evidence_type: params[:evidence_type].to_s,
        reference: params[:reference].to_s, explanation: params[:explanation].to_s)
      redirect_to inbox_path, result.success? ? { notice: "Evidence recorded: #{result.submission.fetch("status")}. #{result.submission.fetch("reason")}" } : { alert: result.error }
    end
  end
end
