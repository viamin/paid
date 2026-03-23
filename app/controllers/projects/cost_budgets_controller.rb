# frozen_string_literal: true

module Projects
  class CostBudgetsController < ApplicationController
    before_action :set_project
    before_action :set_cost_budget, only: [ :update, :destroy ]

    def create
      authorize @project, :update?
      @cost_budget = @project.cost_budgets.build(cost_budget_params)

      if @cost_budget.save
        redirect_to project_cost_dashboard_path(@project), notice: "Budget limit created."
      else
        @stats = Projects::CostDashboardStats.call(project: @project)
        @cost_budgets = @project.cost_budgets.index_by(&:id)
        render "projects/cost_dashboards/show", status: :unprocessable_content
      end
    end

    def update
      authorize @project, :update?

      if @cost_budget.update(cost_budget_params)
        redirect_to project_cost_dashboard_path(@project), notice: "Budget limit updated."
      else
        @stats = Projects::CostDashboardStats.call(project: @project)
        @cost_budgets = @project.cost_budgets.index_by(&:id)
        @cost_budget = @project.cost_budgets.build
        render "projects/cost_dashboards/show", status: :unprocessable_content
      end
    end

    def destroy
      authorize @project, :update?
      @cost_budget.destroy!
      redirect_to project_cost_dashboard_path(@project), notice: "Budget limit removed."
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_cost_budget
      @cost_budget = @project.cost_budgets.find(params[:id])
    end

    def cost_budget_params
      params.require(:cost_budget).permit(:budget_type, :limit_dollars, :alert_threshold_percent)
    end
  end
end
