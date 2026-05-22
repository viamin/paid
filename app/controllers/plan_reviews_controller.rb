# frozen_string_literal: true

class PlanReviewsController < ApplicationController
  before_action :authenticate_user!
  before_action :set_pending_review, only: %i[approve reject revise]

  def index
    authorize :plan_review, :index?
    @plan_reviews = DecompositionDecision
      .where(outcome: "plan_pending_review")
      .includes(:project, :issue)
      .order(created_at: :desc)
    @plan_reviews = @plan_reviews.where(project_id: policy_scope(Project).select(:id))
  end

  def approve
    authorize :plan_review, :manage?
    send_signal("approve_plan")
    redirect_to plan_reviews_path, notice: "Plan approved. Sub-issues will be created."
  end

  def reject
    authorize :plan_review, :manage?
    send_signal("reject_plan")
    redirect_to plan_reviews_path, notice: "Plan rejected. No sub-issues will be created."
  end

  def revise
    authorize :plan_review, :manage?
    revised_tasks = parse_revised_tasks
    send_signal("revise_plan", revised_tasks)
    redirect_to plan_reviews_path, notice: "Plan revised. Sub-issues will be created with the updated plan."
  end

  private

  def set_pending_review
    @plan_review = DecompositionDecision.find_by!(
      id: params[:id],
      outcome: "plan_pending_review"
    )
  end

  def send_signal(signal_name, *args)
    Paid.temporal_client.workflow_handle(@plan_review.workflow_id).signal(signal_name, *args)
  rescue Temporalio::Error::RPCError => e
    raise unless e.code == Temporalio::Error::RPCError::Code::NOT_FOUND

    flash[:alert] = "The plan review workflow is no longer active."
    redirect_to plan_reviews_path
  end

  def parse_revised_tasks
    params.require(:tasks).map do |task|
      task.permit(:title, :description).to_h.deep_symbolize_keys
    end
  end
end
