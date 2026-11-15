# frozen_string_literal: true

module Projects
  # Project-page unified work-item panel: the tickets assigned to this
  # repository-backed project and their issue-level execution defaults.
  # Guarded by the project-scoped unified_work_items rollout flag.
  #
  # @spec UNIFIED-WORK-ITEMS-004 UNIFIED-WORK-ITEMS-005 UNIFIED-WORK-ITEMS-009
  class WorkItemsController < ApplicationController
    include AuditLogging

    before_action :set_project
    before_action :require_rollout_guard!
    before_action :set_work_item, only: [ :set_default_execution ]
    skip_after_action :verify_authorized, only: :index

    def index
      @work_items = WorkItems::Browse.call(account: @project.account, project: @project)
        .merge(policy_scope(WorkItem)).to_a
    end

    def set_default_execution
      authorize @work_item, :override?

      target = @project.account.projects.find_by(id: params[:target_project_id])
      if target.nil?
        redirect_to project_work_items_path(@project), alert: "Select one of the ticket's assigned projects."
        return
      end

      WorkItems::SetDefaultExecutionProject.call(work_item: @work_item, project: target)
      audit_event("work_item.default_execution_set",
        metadata: { work_item_id: @work_item.id, project_id: target.id })
      redirect_to project_work_items_path(@project), notice: "Default execution project updated."
    rescue WorkItems::SetDefaultExecutionProject::NotAssignedError
      redirect_to project_work_items_path(@project),
        alert: "The project must be assigned to the ticket before it can be the default."
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def require_rollout_guard!
      return if Automation::Providers::UnifiedWorkItemsRolloutGuard.enabled?(@project)

      head :not_found
    end

    def set_work_item
      @work_item = @project.work_items.merge(policy_scope(WorkItem)).find(params[:id])
    end
  end
end
