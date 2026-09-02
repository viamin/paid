# frozen_string_literal: true

module Knowledge
  class QualityController < ApplicationController
    before_action :authenticate_user!
    before_action :set_project

    # GET /projects/:project_id/knowledge/quality
    def show
      authorize @project, :show?
      @report = Knowledge::Quality::Lint.call(project: @project)
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end
  end
end
