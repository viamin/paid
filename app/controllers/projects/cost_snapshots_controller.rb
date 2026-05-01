# frozen_string_literal: true

module Projects
  class CostSnapshotsController < ApplicationController
    before_action :set_project

    def show
      authorize @project
      @summary = StatsSummary.call(project: @project, budgets: @project.cost_budgets.load)
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
