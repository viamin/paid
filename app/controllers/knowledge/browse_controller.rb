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
      artifact_scope = KnowledgeArtifact.active
        .for_project(@project)
        .by_type(@artifact_type)
        .select(<<~SQL.squish)
          knowledge_artifacts.*,
          (
            SELECT COUNT(*)
            FROM knowledge_chunks
            WHERE knowledge_chunks.knowledge_artifact_id = knowledge_artifacts.id
          ) AS chunks_count
        SQL
        .order(:identifier, :id)

      @pagy, @artifacts = pagy(artifact_scope, limit: 50)
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
