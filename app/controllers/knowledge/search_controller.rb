# frozen_string_literal: true

module Knowledge
  class SearchController < ApplicationController
    before_action :authenticate_user!
    skip_after_action :verify_authorized, only: [ :index, :project_search ]

    def index
      @projects = policy_scope(Project).order(:name)
      @project_artifact_counts = KnowledgeArtifact.active
        .where(project_id: @projects.select(:id))
        .group(:project_id, :artifact_type)
        .count
        .each_with_object({}) do |((project_id, type), count), hash|
          (hash[project_id] ||= {})[type] = count
        end
    end

    def project_search
      set_project
      authorize @project, :show?
      resolve_semantic_search_info
      @results = nil
    end

    def project_search_results
      set_project
      authorize @project, :show?
      @query = params[:q].to_s.strip
      resolve_semantic_search_info

      if @query.blank?
        @error = "Please enter a search query."
        return render :project_search
      end

      perform_search
      render :project_search
    end

    # Legacy global search endpoint — kept for backward compatibility
    def search
      @projects = policy_scope(Project).order(:name)
      @project = @projects.find_by(id: params[:project_id])
      @query = params[:q].to_s.strip

      if @project.nil?
        skip_authorization
        @project_artifact_counts = {}
        @error = "Please select a project to search."
        return render :index
      end

      authorize @project, :show?
      resolve_semantic_search_info

      if @query.blank?
        @error = "Please enter a search query."
        return redirect_to project_knowledge_search_path(@project)
      end

      perform_search
      render :project_search
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def perform_search
      mode = @search_mode
      provider_config = mode == "exact" ? nil : @project.knowledge_embedding_provider_configuration

      if provider_config.nil?
        @search_mode = mode = "exact"
        api_key = nil
        api_base_url = nil
      else
        api_key = provider_config.api_key
        api_base_url = provider_config.api_base_url
      end

      result = ::Knowledge::Search.call(
        project: @project,
        query: @query,
        mode: mode,
        artifact_type: params[:type].presence,
        limit: 20,
        api_key: api_key,
        api_base_url: api_base_url
      )

      @results = result[:results]
      @meta = result[:meta]
    end

    def resolve_semantic_search_info
      normalized_mode = ::Knowledge::Search::MODES.include?(params[:mode]) ? params[:mode] : nil

      if @project.nil?
        @semantic_search_source = :unknown
        @semantic_search_provider_config = nil
        @semantic_search_api_key_record = nil
        @search_mode = normalized_mode || ::Knowledge::Search::DEFAULT_MODE
        return
      end

      config = @project.knowledge_embedding_provider_configuration
      @semantic_search_provider_config = config
      @semantic_search_api_key_record = config&.api_key_record

      if config&.source == :user_key
        @semantic_search_source = :user_key
      elsif config&.source == :platform_env
        @semantic_search_source = :platform_env
      else
        @semantic_search_source = :none
      end

      if @semantic_search_source == :none
        @search_mode = "exact"
      else
        @search_mode = normalized_mode || ::Knowledge::Search::DEFAULT_MODE
      end
    end
  end
end
