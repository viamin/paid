# frozen_string_literal: true

class PlanReviewsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_pending_review, only: %i[approve reject revise]
  skip_after_action :verify_authorized, only: :index
  skip_after_action :verify_policy_scoped, only: :index

  def index
    redirect_to dashboard_inbox_path(kind: Inbox::Queue::PLAN_REVIEW_KIND), status: :see_other
  end

  def approve
    authorize @plan_review, :manage?, policy_class: PlanReviewPolicy
    return unless send_signal("approve_plan")

    redirect_to redirect_target, notice: "Plan approved. Sub-issues will be created."
  end

  def reject
    authorize @plan_review, :manage?, policy_class: PlanReviewPolicy
    return unless send_signal("reject_plan")

    redirect_to redirect_target, notice: "Plan rejected. No sub-issues will be created."
  end

  def revise
    authorize @plan_review, :manage?, policy_class: PlanReviewPolicy
    revised_tasks = parse_revised_tasks
    return unless send_signal("revise_plan", revised_tasks)

    redirect_to redirect_target, notice: "Plan revised. Sub-issues will be created with the updated plan."
  end

  private

  def set_pending_review
    @plan_review = plan_review_scope.open_plan_reviews.find(params[:id])
  end

  def send_signal(signal_name, *args)
    Paid.temporal_client.workflow_handle(@plan_review.workflow_id).signal(signal_name, *args)
    true
  rescue Temporalio::Error::RPCError => e
    raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND

    redirect_to redirect_target, alert: "The plan review workflow is no longer active."
    false
  end

  def parse_revised_tasks
    params.require(:tasks).map do |task|
      task.permit(:title, :description).to_h.deep_symbolize_keys
    end
  end

  def plan_review_scope
    policy_scope(DecompositionDecision, policy_scope_class: PlanReviewPolicy::Scope)
  end

  def redirect_target
    requested = normalized_return_to(params[:return_to])
    return requested if requested.present? && requested.start_with?(dashboard_inbox_path)

    dashboard_inbox_path(kind: Inbox::Queue::PLAN_REVIEW_KIND)
  end

end
