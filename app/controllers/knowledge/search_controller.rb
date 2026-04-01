# frozen_string_literal: true

module Knowledge
  class SearchController < ApplicationController
    before_action :authenticate_user!
    skip_after_action :verify_authorized, only: :index

    def index
      @projects = policy_scope(Project).order(:name)
      @project = @projects.find_by(id: params[:project_id])
      @results = nil
    end

    def search
      @projects = policy_scope(Project).order(:name)
      @project = @projects.find_by(id: params[:project_id])
      @query = params[:q].to_s.strip

      if @project.nil?
        skip_authorization
        @error = "Please select a project."
        return render :index
      end

      authorize @project, :show?

      if @query.blank?
        @error = "Please enter a search query."
        return render :index
      end

      mode = params[:mode].presence || "hybrid"

      unless @project.semantic_search_available?
        # When no API key is configured, only exact search is available.
        mode = "exact"
        api_key = nil
      else
        api_key = @project.openai_api_key unless mode == "exact"
      end

      result = ::Knowledge::Search.call(
        project: @project,
        query: @query,
        mode: mode,
        artifact_type: params[:type].presence,
        limit: 20,
        api_key: api_key
      )

      @results = result[:results]
      @meta = result[:meta]

      render :index
    end
  end
end
