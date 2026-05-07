# frozen_string_literal: true

require "securerandom"

module Projects
  class ScreenshotConfigsController < ApplicationController
    SUGGESTED_CONFIG_CACHE_TTL = 10.minutes

    before_action :set_project

    def detect
      authorize @project, :update?

      result = Projects::Screenshots::DetectFramework.call(project: @project)

      respond_to do |format|
        format.html do
          flash[:screenshot_config_suggestion_cache_key] = cache_suggested_yaml(result.suggested_yaml)
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

    def cache_suggested_yaml(suggested_yaml)
      cache_key = [
        "projects",
        @project.id,
        "screenshot-config-suggestion",
        SecureRandom.uuid
      ].join("/")
      Rails.cache.write(cache_key, suggested_yaml, expires_in: SUGGESTED_CONFIG_CACHE_TTL)
      cache_key
    end
  end
end
