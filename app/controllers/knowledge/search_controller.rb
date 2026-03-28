# frozen_string_literal: true

module Knowledge
  class SearchController < ApplicationController
    before_action :authenticate_user!
    skip_after_action :verify_authorized
    skip_after_action :verify_policy_scoped

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
        flash.now[:alert] = "Please select a project."
        return render :index
      end

      if @query.blank?
        flash.now[:alert] = "Please enter a search query."
        return render :index
      end

      authorize @project, :show?

      result = ::Knowledge::Search.call(
        project: @project,
        query: @query,
        mode: params[:mode].presence || "hybrid",
        artifact_type: params[:type].presence,
        limit: 20
      )

      @results = result[:results]
      @meta = result[:meta]

      respond_to do |format|
        format.html { render :index }
        format.turbo_stream
      end
    end
  end
end
