# frozen_string_literal: true

# Account-scoped unified work-item browser: unassigned-first listing with
# filters, individual/bulk assignment, review-flag resolution, and
# execution-project-aware run starts. Every action is guarded by the
# default-off unified_work_items rollout flag.
#
# @spec UNIFIED-WORK-ITEMS-004 UNIFIED-WORK-ITEMS-005 UNIFIED-WORK-ITEMS-009
class WorkItemsController < ApplicationController
  include AuditLogging

  before_action :require_rollout_guard!
  before_action :set_work_item, only: [ :show, :assign, :clear_review_flag, :start_run ]
  skip_after_action :verify_authorized, only: :index

  def index
    @pagy, @work_items = pagy(browse_scope.includes(:work_item_assignments, :projects))
  end

  def show
    authorize @work_item
    @projects = policy_scope(Project).order(:name)
  end

  def assign
    authorize @work_item, :show?

    projects = assignable_projects
    if projects.empty?
      redirect_to work_item_path(@work_item), alert: "No assignable project was selected."
      return
    end

    WorkItems::AssignToProjects.call(work_items: @work_item, projects:, actor: current_user)
    audit_event("work_item.assigned", metadata: { work_item_id: @work_item.id, project_ids: projects.map(&:id) })
    redirect_to work_item_path(@work_item), notice: "Ticket assigned."
  end

  def clear_review_flag
    authorize @work_item, :review?

    @work_item.clear_review_flag!
    audit_event("work_item.review_flag_cleared", metadata: { work_item_id: @work_item.id })
    redirect_to work_item_path(@work_item), notice: "Review flag cleared."
  end

  def start_run
    authorize @work_item, :show?

    project = WorkItems::ExecutionProjectResolver.call(work_item: @work_item)
    if project.nil?
      redirect_to work_item_path(@work_item), alert: "Assign the ticket to a project before starting a run."
      return
    end

    redirect_to new_project_agent_run_path(project, goal: "create_pr", work_item_id: @work_item.id)
  end

  private

  def require_rollout_guard!
    return if Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled_for_account?(current_account)

    head :not_found
  end

  def set_work_item
    @work_item = policy_scope(WorkItem).find(params[:id])
  end

  def browse_scope
    WorkItems::Browse.call(
      account: current_account,
      provider: params[:provider].presence,
      native_project_id: params[:native_project_id].presence,
      needing_review: ActiveModel::Type::Boolean.new.cast(params[:needing_review]) ? true : nil
    ).merge(policy_scope(WorkItem))
  end

  def assignable_projects
    policy_scope(Project).where(id: Array(params[:project_ids])).select do |project|
      policy(@work_item).assign_to_project?(project)
    end
  end
end
