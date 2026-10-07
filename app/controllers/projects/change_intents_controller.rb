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

    # @spec CHANGE-INTENT-INBOX-001
    # Approves the draft, activates it, and indexes it into the knowledge
    # pipeline. The Inbox entry clears on the next queue render.
    def approve
      authorize @change_intent, :update?, policy_class: ChangeIntentPolicy
      # @spec CHANGE-INTENT-004
      ChangeIntents::Activate.call(change_intent: @change_intent)

      redirect_to safe_return_target, notice: "Change Intent Record approved and added to the knowledge base."
    rescue ChangeIntent::InvalidTransitionError => e
      redirect_to redirect_on_invalid_transition, alert: e.message
    end

    # @spec CHANGE-INTENT-INBOX-001
    # Records the operator's review feedback on the draft. The draft stays
    # in the Inbox under a `requested_changes` state until a follow-up chat
    # or MCP revision updates the draft and the operator re-approves.
    def request_changes
      authorize @change_intent, :update?, policy_class: ChangeIntentPolicy
      ChangeIntents::RequestChanges.call(
        change_intent: @change_intent,
        reason: params[:reason].to_s
      )

      redirect_to safe_return_target, notice: "Change Intent Record marked for changes."
    rescue ChangeIntent::InvalidTransitionError => e
      redirect_to redirect_on_invalid_transition, alert: e.message
    end

    def discard
      authorize @change_intent, :update?, policy_class: ChangeIntentPolicy
      ChangeIntents::DiscardDraft.call(change_intent: @change_intent)

      redirect_to safe_return_target, notice: "Proposed Change Intent Record discarded."
    rescue ChangeIntent::InvalidTransitionError => e
      redirect_to redirect_on_invalid_transition, alert: e.message
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_change_intent
      @change_intent = @project.change_intents.find(params[:id])
    end

    # Returns the safe return target when present (inbox-driven flows
    # redirect back to the inbox pane that initiated the action). Falls back
    # to the project page, matching the pre-inbox lifecycle.
    def safe_return_target
      inbox_return_target(project_path(@project))
    end

    def redirect_on_invalid_transition
      inbox_return_target(project_change_intent_path(@project, @change_intent))
    end

    # @spec CHANGE-INTENT-INBOX-001
    def inbox_return_target(fallback)
      target = normalized_return_to(params[:return_to])
      return target if target.present? && target.start_with?(inbox_path)

      fallback
    end
  end
end
