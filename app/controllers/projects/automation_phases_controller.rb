# frozen_string_literal: true

module Projects
  # RDR-077 §2/§6: project phase settings, their migration preview, and grant
  # inspection/revocation for the project's work.
  #
  # @spec AUTOMATION-PHASES-002 @spec AUTOMATION-PHASES-008 @spec AUTOMATION-PHASES-015
  class AutomationPhasesController < ApplicationController
    before_action :set_project

    def show
      authorize @project, :update?

      load_phase_data
    end

    # @spec AUTOMATION-PHASES-002
    def update
      authorize @project, :update?

      result = Automation::PhaseSettings::Update.call(
        project: @project,
        params: phase_settings_params,
        user: current_user
      )

      load_phase_data
      @saved_settings = result.settings

      respond_to do |format|
        format.html { redirect_to project_automation_phases_path(@project), notice: "Automation phases updated." }
        format.json { render json: { settings: result.settings.to_h, enabled_transitions: result.enabled_transitions } }
      end
    end

    # @spec AUTOMATION-PHASES-015
    def preview
      authorize @project, :update?

      render json: Automation::Phases::MigrationPreview.call(project: @project, user: current_user).to_h
    end

    # @spec AUTOMATION-PHASES-008
    def revoke_grant
      authorize @project, :update?

      grant = @project.work_item_continuation_grants.find(params[:id])
      grant.revoke!(user: current_user)

      respond_to do |format|
        format.html { redirect_to project_automation_phases_path(@project), notice: "Continuation grant revoked." }
        format.json { render json: { revoked: true, grant_id: grant.id } }
      end
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def load_phase_data
      @phase_settings = Automation::PhaseSettings.call(@project)
      @phases = Automation::Phases::ALL
      @rollout_enabled = Automation::RolloutGuard.enabled?(@project)
      @active_grants = @project.work_item_continuation_grants.active
        .includes(:issue).order(created_at: :desc).limit(50)
      @migration_preview = Automation::Phases::MigrationPreview.call(project: @project, user: current_user)
    end

    def phase_settings_params
      raw = params.fetch(:automation_phase_settings, {})
      permitted = params.require(:project).permit(
        phases: Automation::Phases::ALL,
        release: ActiveModel::Type::Boolean.new,
        deployment: ActiveModel::Type::Boolean.new
      ).to_h
      permitted[:phases] = permitted[:phases].to_h.symbolize_keys
      permitted.presence || raw.to_h
    end
  end
end