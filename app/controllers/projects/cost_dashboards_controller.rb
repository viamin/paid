# frozen_string_literal: true

module Projects
  class CostDashboardsController < ApplicationController
    before_action :set_project

    def show
      authorize @project, :show?
      @stats = Projects::CostDashboardStats.call(project: @project)
      @cost_budgets = @project.cost_budgets.index_by(&:id)
      @cost_budget ||= CostBudget.new
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
