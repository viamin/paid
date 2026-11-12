# frozen_string_literal: true

module Projects
  # RDR-080: the explicit hold on delegated work. Placing and releasing a
  # hold are ownership acts, so the same project policy that guards the
  # posture selection guards them too. The hold never changes the posture,
  # the admission snapshots, or the delegated evidence.
  #
  # @spec PROJECT-DELEGATION-010
  class DelegationHoldsController < ApplicationController
    before_action :set_project

    def create
      authorize @project, :manage_delegation_hold?

      ProjectDelegation::PlaceHold.call(
        project: @project,
        actor: current_user,
        reason: params.dig(:project_delegation_hold, :reason)
      )

      redirect_to project_automation_phases_path(@project), notice: "Delegated work is on hold."
    rescue ProjectDelegation::PlaceHold::Error => e
      redirect_to project_automation_phases_path(@project), alert: e.message
    end

    def destroy
      authorize @project, :manage_delegation_hold?

      ProjectDelegation::ReleaseHold.call(project: @project, actor: current_user)

      redirect_to project_automation_phases_path(@project), notice: "Delegation hold released."
    rescue ProjectDelegation::ReleaseHold::Error => e
      redirect_to project_automation_phases_path(@project), alert: e.message
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
