# frozen_string_literal: true

# @spec FEATURE-APPROVAL-012 @spec FEATURE-APPROVAL-013 @spec FEATURE-APPROVAL-020
class FeatureIntentsController < ApplicationController
  before_action :set_feature_intent, only: %i[approve cancel reopen respond_to_decision]

  # Background discovery and cancellation history remain reachable here rather
  # than becoming non-actionable entries in the Inbox queue.
  # @spec FEATURE-APPROVAL-020
  def index
    authorize FeatureIntent, :index?, policy_class: FeatureIntentPolicy
    scope = policy_scope(FeatureIntent).includes(:project, :cancelled_by)
    @feature_intents = scope.where.not(status: FeatureIntent::TERMINAL_STATUSES).order(created_at: :desc, id: :desc)
    @cancelled_feature_intents = scope.where(status: "cancelled").order(cancelled_at: :desc, id: :desc)
  end

  def approve
    authorize @feature_intent, :approve?, policy_class: FeatureIntentPolicy

    FeatureIntents::MarkApproved.call(feature_intent: @feature_intent, actor: current_user, source: "inbox")
    redirect_to inbox_path(kind: Inbox::Queue::FEATURE_DECISION_KIND), notice: "Feature approved."
  rescue FeatureIntents::MarkApproved::NotAuthorizedError
    user_not_authorized
  rescue FeatureIntents::MarkApproved::NotReadyError => e
    redirect_to inbox_entry_path(feature_decision_entry_id),
      alert: "Not ready to approve: #{e.blockers.map(&:message).join(" ")}"
  rescue FeatureIntent::InvalidTransitionError => e
    # Defense in depth: `ApprovalReadiness` reports the same status rule, so
    # this should not normally fire. It guards a race between render and
    # action (status changed underneath us) and any caller that bypasses the
    # Inbox UI; without it, the user gets a 500 instead of the same graceful
    # redirect every other rejection path uses.
    redirect_to inbox_entry_path(feature_decision_entry_id),
      alert: "Not ready to approve: feature is in '#{@feature_intent.status}' state and cannot be approved yet."
  end

  def cancel
    authorize @feature_intent, :cancel?, policy_class: FeatureIntentPolicy

    FeatureIntents::Cancel.call(feature_intent: @feature_intent, actor: current_user, **cancellation_attributes)
    redirect_to feature_intents_path, notice: "Feature proposal declined. It remains available in proposal history."
  rescue FeatureIntents::Cancel::NotAuthorizedError
    user_not_authorized
  rescue FeatureIntents::Cancel::InvalidCancellationError, FeatureIntent::InvalidTransitionError => e
    redirect_to feature_intents_path, alert: e.message
  end

  def reopen
    authorize @feature_intent, :reopen?, policy_class: FeatureIntentPolicy

    FeatureIntents::Reopen.call(feature_intent: @feature_intent, actor: current_user)
    redirect_to feature_intents_path, notice: "Feature proposal reopened for discovery."
  rescue FeatureIntents::Reopen::NotAuthorizedError
    user_not_authorized
  rescue FeatureIntent::InvalidTransitionError => e
    redirect_to feature_intents_path, alert: e.message
  end

  # @spec FACET-CONFIDENCE-019
  def respond_to_decision
    authorize @feature_intent, :approve?, policy_class: FeatureIntentPolicy
    decision = @feature_intent.feature_intent_decisions.find(params[:decision_id])
    FeatureIntents::RespondToDecision.call(decision:, actor: current_user, answer: params[:answer])
    FeatureIntents::ResponseDrafts.clear(session, feature_intent: @feature_intent, decision_id: decision.id)

    redirect_to inbox_entry_path(feature_decision_entry_id), notice: "Response saved."
  rescue FeatureIntents::RespondToDecision::InvalidResponseError, FeatureIntents::RespondToDecision::StaleDecisionError => e
    save_response_draft(decision) if response_draft_fits_session?
    redirect_to inbox_entry_path(feature_decision_entry_id), alert: e.message
  end

  private

  def set_feature_intent
    @feature_intent = FeatureIntentPolicy::Scope.new(current_user, FeatureIntent).resolve.find(params[:id])
  end

  def feature_decision_entry_id
    "#{Inbox::Queue::FEATURE_DECISION_KIND}:#{@feature_intent.id}"
  end

  def cancellation_attributes
    params.permit(:cancellation_reason, :replacement_reference).to_h.symbolize_keys
  end

  def save_response_draft(decision)
    FeatureIntents::ResponseDrafts.save(session, feature_intent: @feature_intent, decision_id: decision.id, answer: params[:answer])
  end

  def response_draft_fits_session?
    params[:answer].to_s.length <= FeatureIntents::ResponseDrafts::MAX_ANSWER_CHARS
  end
end
