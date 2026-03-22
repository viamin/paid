# frozen_string_literal: true

module Projects
  class CostDashboardsController < ApplicationController
    before_action :set_project

    def show
      authorize @project, :show?
      @stats = Projects::CostDashboardStats.call(project: @project)
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
