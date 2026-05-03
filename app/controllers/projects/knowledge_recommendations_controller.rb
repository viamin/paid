# frozen_string_literal: true

module Projects
  class KnowledgeRecommendationsController < ApplicationController
    before_action :set_project
    before_action :set_recommendation, only: :update

    def index
      authorize @project, :show?
      @recommendations = @project.knowledge_recommendations.order(created_at: :desc)
      @pending = @recommendations.pending.by_priority
      @resolved = @recommendations.where.not(status: "pending")
    end

    def update
      authorize @project, :update?

      case params[:action_type]
      when "accept"
        @recommendation.accept!
      when "dismiss"
        @recommendation.dismiss!(reason: params[:dismissal_reason])
      end

      respond_to do |format|
        format.turbo_stream
        format.html { redirect_to project_knowledge_recommendations_path(@project) }
      end
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_recommendation
      @recommendation = @project.knowledge_recommendations.find(params[:id])
    end
  end
end
