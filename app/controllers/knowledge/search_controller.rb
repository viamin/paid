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

      result = ::Knowledge::Search.call(
        project: @project,
        query: @query,
        mode: params[:mode].presence || "hybrid",
        artifact_type: params[:type].presence,
        limit: 20
      )

      @results = result[:results]
      @meta = result[:meta]

      render :index
    end
  end
end
