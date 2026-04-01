# frozen_string_literal: true

module Knowledge
  class SearchController < ApplicationController
    before_action :authenticate_user!
    skip_after_action :verify_authorized, only: :index

    def index
      @projects = policy_scope(Project).order(:name)
      @project = @projects.find_by(id: params[:project_id])
      @results = nil
      resolve_semantic_search_info
    end

    def search
      @projects = policy_scope(Project).order(:name)
      @project = @projects.find_by(id: params[:project_id])
      @query = params[:q].to_s.strip

      if @project.nil?
        skip_authorization
        resolve_semantic_search_info
        @error = "Please select a project."
        return render :index
      end

      authorize @project, :show?
      resolve_semantic_search_info

      if @query.blank?
        @error = "Please enter a search query."
        return render :index
      end

      mode = @search_mode

      unless @project.semantic_search_available?
        @search_mode = mode = "exact"
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

    private

    def resolve_semantic_search_info
      if @project.nil?
        @semantic_search_source = :none
        @openai_key_record = nil
        @search_mode = params[:mode].presence || "exact"
        return
      end

      record = @project.openai_provider_api_key_record
      if record
        @semantic_search_source = :user_key
        @openai_key_record = record
      elsif ENV["OPENAI_API_KEY"].present?
        @semantic_search_source = :platform_env
        @openai_key_record = nil
      else
        @semantic_search_source = :none
        @openai_key_record = nil
      end

      @search_mode = params[:mode].presence || (@semantic_search_source == :none ? "exact" : "hybrid")
    end
  end
end
