# frozen_string_literal: true

module Knowledge
  class ArtifactsController < ApplicationController
    before_action :authenticate_user!
    skip_after_action :verify_policy_scoped

    def show
      @artifact = KnowledgeArtifact.find(params[:id])
      @project = @artifact.project
      authorize @project, :show?

      @chunks = @artifact.active_ordered_chunks
      @collector_run = @artifact.collector_run
      @project_version = @collector_run.project_version
    end
  end
end
