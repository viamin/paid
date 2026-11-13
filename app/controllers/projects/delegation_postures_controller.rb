# frozen_string_literal: true

module Projects
  # RDR-080 posture selection surface: the settings form posts here, and the
  # guarded write path enforces the owner/project-admin authorization and the
  # rollout guards before anything is stored or audited.
  #
  # @spec PROJECT-DELEGATION-001
  class DelegationPosturesController < ApplicationController
    def update
      project = policy_scope(Project).find(params[:project_id])
      authorize project, :select_delegation_posture?

      update_posture(project)

      redirect_to project_automation_phases_path(project), notice: "Delegation posture updated."
    rescue ProjectDelegation::Rollback::ReasonRequired, ProjectDelegation::SelectPosture::Error => e
      redirect_to project_automation_phases_path(project), alert: e.message
    end

    private

    # @spec PROJECT-DELEGATION-006
    def update_posture(project)
      return rollback(project) if posture_params[:level] == ProjectDelegation::Posture::CONSERVATIVE

      ProjectDelegation::SelectPosture.call(project:, actor: current_user, level: posture_params[:level])
    end

    def rollback(project)
      ProjectDelegation::Rollback.call(project:, actor: current_user, reason: posture_params[:reason])
    end

    def posture_params
      params.require(:project_delegation_posture).permit(:level, :reason)
    end
  end
end
