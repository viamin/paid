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

      ProjectDelegation::SelectPosture.call(
        project: project,
        actor: current_user,
        level: params.dig(:project_delegation_posture, :level)
      )

      redirect_to project_automation_phases_path(project), notice: "Delegation posture updated."
    rescue ProjectDelegation::SelectPosture::Error => e
      redirect_to project_automation_phases_path(project), alert: e.message
    end
  end
end
