# frozen_string_literal: true

module Projects
  # Human settlement of a settled-intent checkpoint (RDR-080): an authorized
  # project member settles, rejects, or amends the grouped material questions
  # through the same service every other surface must use.
  # @spec PROJECT-DELEGATION-002
  class IntentCheckpointsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project
    before_action :set_checkpoint
    before_action :authorize_settlement

    def settle
      settlement = ProjectDelegation::IntentCheckpoint::Settle.call(
        checkpoint: @checkpoint,
        actor: current_user,
        disposition: params.require(:disposition),
        answers: settle_answers
      )
      redirect_back fallback_location: project_path(@project), notice: notice_for(settlement)
    rescue ProjectDelegation::IntentCheckpoint::Settle::Error => e
      redirect_back fallback_location: project_path(@project), alert: e.message
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_checkpoint
      @checkpoint = @project.delegation_intent_checkpoints.find(params[:id])
    end

    def authorize_settlement
      authorize @project, :settle_intent_checkpoint?
    end

    def settle_answers
      Array(params[:answers]).filter_map do |entry|
        entry.permit(:group_key, :answer, :amendment).to_h if entry.is_a?(ActionController::Parameters)
      end
    end

    def notice_for(settlement)
      case settlement.disposition
      when "rejected" then "Rejected the material intent questions; they stay human decisions."
      when "amended" then "Amended and settled the material intent questions."
      else "Settled the material intent questions and bound them to the current revisions."
      end
    end
  end
end
