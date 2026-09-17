# frozen_string_literal: true

# @spec FEATURE-APPROVAL-007 @spec FEATURE-APPROVAL-008
class FeatureIntentsController < ApplicationController
  before_action :set_feature_intent, only: :approve

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

  private

  def set_feature_intent
    @feature_intent = FeatureIntentPolicy::Scope.new(current_user, FeatureIntent).resolve.find(params[:id])
  end

  def feature_decision_entry_id
    "#{Inbox::Queue::FEATURE_DECISION_KIND}:#{@feature_intent.id}"
  end
end
