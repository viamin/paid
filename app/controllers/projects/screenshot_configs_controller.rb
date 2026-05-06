# frozen_string_literal: true

module Projects
  class ScreenshotConfigsController < ApplicationController
    before_action :set_project

    def detect
      authorize @project, :update?

      result = Screenshots::DetectFramework.call(project: @project)

      respond_to do |format|
        format.html do
          flash[:screenshot_config_suggestion_yaml] = result.suggested_yaml
          flash[:screenshot_config_framework] = result.framework.to_s
          flash[:screenshot_config_confidence] = result.confidence
          redirect_to edit_project_path(@project),
            notice: "Suggested screenshot config generated for #{result.framework.to_s.humanize}."
        end

        format.json do
          render json: result.to_h.merge(suggested_yaml: result.suggested_yaml)
        end
      end
    rescue GithubClient::Error => e
      respond_to do |format|
        format.html do
          redirect_to edit_project_path(@project), alert: "Could not detect screenshot config: #{e.message}"
        end

        format.json do
          render json: { error: "Could not detect screenshot config: #{e.message}" }, status: :unprocessable_content
        end
      end
    end

    private

    def set_project
      @project = policy_scope(Project).includes(:github_token, :created_by).find(params[:project_id])
    end
  end
end
