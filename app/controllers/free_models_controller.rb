# frozen_string_literal: true

class FreeModelsController < ApplicationController
  before_action :load_projects

  def index
    authorize current_account, :show?

    @project = selected_project
    @catalog = FreeModels::Catalog.call(project: @project)
    @openrouter_free_runner = policy_scope(Runner).find { |runner| runner.free_model_policy? }
  end

  def project_preferences
    @project = policy_scope(Project).find(params[:project_id])
    authorize @project, :update?

    preferences = @project.model_preferences.is_a?(Hash) ? @project.model_preferences.deep_dup : {}
    preferences["excluded_free_model_ids"] = excluded_free_model_ids_param

    @project.update!(model_preferences: preferences)

    redirect_to free_models_path(project_id: @project.id), notice: "Free model preferences saved."
  end

  private

  def load_projects
    @projects = policy_scope(Project).order(:name)
  end

  def selected_project
    @projects.find_by(id: params[:project_id]) || @projects.first
  end

  def excluded_free_model_ids_param
    params.fetch(:project, {})
      .fetch(:excluded_free_model_ids, [])
      .reject(&:blank?)
      .uniq
  end
end
