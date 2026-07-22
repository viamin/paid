# frozen_string_literal: true

module Projects
  class ScalingDashboardsController < ApplicationController
    before_action :set_project

    def show
      authorize @project, :show?
      @stats = Projects::ScalingDashboardStats.call(project: @project)
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
