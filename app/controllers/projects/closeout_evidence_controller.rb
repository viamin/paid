# frozen_string_literal: true

module Projects
  class CloseoutEvidenceController < ApplicationController
    before_action :set_project

    # @spec PARTIAL-CLOSEOUT-032
    def create
      authorize @project, :run_agent?
      notification = @project.account.notifications.find(params[:notification_id])
      raise ArgumentError, "notification does not belong to this project" unless notification.resolved_project == @project
      result = PartialCloseouts::SubmitEvidence.call(notification:, actor: current_user,
        prerequisite_identity: params[:prerequisite_identity], **evidence_params)
      redirect_to inbox_entry_path(params[:inbox_entry_id]), notice: result.reason
    rescue ArgumentError => error
      redirect_to inbox_entry_path(params[:inbox_entry_id]), alert: error.message
    end

    private

    def set_project = @project = policy_scope(Project).find(params[:project_id])

    def evidence_params
      params.fetch("prerequisite_#{params[:prerequisite_identity]}").permit(:evidence_url, :explanation).to_h.symbolize_keys
    end
  end
end
