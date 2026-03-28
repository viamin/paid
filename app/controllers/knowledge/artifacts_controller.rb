# frozen_string_literal: true

module Knowledge
  class ArtifactsController < ApplicationController
    before_action :authenticate_user!

    def show
      @artifact = KnowledgeArtifact.joins(:project).merge(policy_scope(Project)).find(params[:id])
      @project = @artifact.project
      authorize @project, :show?

      @chunks = @artifact.chunks.where(status: %w[active stale]).order(created_at: :asc)
      @collector_run = @artifact.collector_run
      @project_version = @collector_run.project_version
    end
  end
end
