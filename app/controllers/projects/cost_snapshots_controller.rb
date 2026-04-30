# frozen_string_literal: true

class Projects::CostSnapshotsController < ApplicationController
  before_action :set_project

  def show
    authorize @project
    @summary = Projects::StatsSummary.call(project: @project, budgets: @project.cost_budgets.load)
  end

  private

  def set_project
    @project = policy_scope(Project).find(params[:project_id])
  end
end
