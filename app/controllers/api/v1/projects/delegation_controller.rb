# frozen_string_literal: true

module Api
  module V1
    module Projects
      # The delegation projection over the mobile API: the same shared read
      # model the settings page, Inbox, and MCP consume, so no API client
      # infers authority from labels, approvals, or queue state.
      # @spec PROJECT-DELEGATION-005
      class DelegationController < BaseController
        before_action -> { require_scope!(:inbox) }

        def show
          project = policy_scope(Project).find(params[:project_id])
          authorize project, :show?

          render json: ProjectDelegation::Projection.for_project(project).to_h
        end
      end
    end
  end
end
