# frozen_string_literal: true

module Api
  module V1
    module Projects
      # Bearer-token parity for phase settings and continuation-grant lifecycle.
      # @spec AUTOMATION-PHASES-002 AUTOMATION-PHASES-008 AUTOMATION-PHASES-009
      class AutomationPhasesController < BaseController
        before_action -> { require_scope!(:inbox) }
        before_action :set_project

        def show
          authorize @project, :show?
          render json: projection.call
        end

        def update
          authorize @project, :update?
          result = Automation::PhaseSettings::Update.call(project: @project, params: settings_params, user: current_user)
          render json: projection.call.merge(enabled_transitions: result.enabled_transitions)
        rescue ActiveRecord::RecordInvalid, ArgumentError => error
          invalid_request(error)
        end

        def revoke_grant
          authorize @project, :update?
          grant = grant_for
          render json: { revoked: grant.revoke!(user: current_user), grant: projection.grant_payload(grant), continuation_notice: Automation::PhaseSettings::Projection::REVOCATION_NOTICE }
        end

        def extend_grant
          authorize @project, :update?
          grant = grant_for
          plan = Automation::ManualStart::Plan.call(project: @project, user: current_user, phase: grant.start_phase,
            endpoint: params.require(:endpoint), continuation_selected: true)
          extended = grant.extend_to!(endpoint: plan.endpoint)
          raise ArgumentError, "Continuation grant is inactive or already covers that endpoint." unless extended

          render json: { extended:, grant: projection.grant_payload(grant), continuation_notice: plan.notice.selection_summary }
        rescue Automation::ManualStart::Plan::Error, ActionController::ParameterMissing, ArgumentError => error
          invalid_request(error)
        end

        private

        def set_project
          @project = policy_scope(Project).find(params[:project_id])
        end

        def grant_for
          @project.work_item_continuation_grants.find(params[:id])
        end

        def settings_params
          params.require(:automation_phase_settings).permit(:release, :deployment, phases: Automation::Phases::ALL).to_h
        end

        def projection
          @projection ||= Automation::PhaseSettings::Projection.new(project: @project)
        end
      end
    end
  end
end
