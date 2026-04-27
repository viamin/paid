# frozen_string_literal: true

module Knowledge
  class BrowseController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project

    def index
      authorize @project, :show?
      @artifact_counts = KnowledgeArtifact.active
        .for_project(@project)
        .group(:artifact_type)
        .count
        .sort_by { |_, count| -count }
      @total_artifacts = @artifact_counts.sum(&:last)
    end

    def show
      authorize @project, :show?
      @artifact_type = params[:id]
      @artifacts = KnowledgeArtifact.active
        .for_project(@project)
        .by_type(@artifact_type)
        .left_joins(:knowledge_chunks)
        .select("knowledge_artifacts.*, COUNT(knowledge_chunks.id) AS chunks_count")
        .group("knowledge_artifacts.id")
        .order(:identifier)
        .limit(100)
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
