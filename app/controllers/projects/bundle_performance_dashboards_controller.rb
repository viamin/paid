# frozen_string_literal: true

module Projects
  class BundlePerformanceDashboardsController < ApplicationController
    before_action :set_project

    def show
      authorize @project, :show?
      @stats = Projects::BundlePerformanceDashboardStats.call(project: @project)
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
