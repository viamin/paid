# frozen_string_literal: true

module Projects
  # Surfaces draft Change Intent Records produced by issue enhancement and
  # provides the human approve/discard path. A draft stays `draft` until a
  # reviewer approves it, so it never enters the knowledge pipeline on its own.
  class ChangeIntentsController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project
    before_action :set_change_intent

    def show
      authorize @change_intent, :show?, policy_class: ChangeIntentPolicy
    end

    def approve
      authorize @change_intent, :update?, policy_class: ChangeIntentPolicy
      # @spec CHANGE-INTENT-004
      ChangeIntents::Activate.call(change_intent: @change_intent)

      redirect_to project_path(@project), notice: "Change Intent Record approved and added to the knowledge base."
    rescue ChangeIntent::InvalidTransitionError => e
      redirect_to project_change_intent_path(@project, @change_intent), alert: e.message
    end

    def discard
      authorize @change_intent, :update?, policy_class: ChangeIntentPolicy
      ChangeIntents::DiscardDraft.call(change_intent: @change_intent)

      redirect_to project_path(@project), notice: "Proposed Change Intent Record discarded."
    rescue ChangeIntent::InvalidTransitionError => e
      redirect_to project_change_intent_path(@project, @change_intent), alert: e.message
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_change_intent
      @change_intent = @project.change_intents.find(params[:id])
    end
  end
end
