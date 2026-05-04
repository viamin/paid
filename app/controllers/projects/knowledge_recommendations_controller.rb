# frozen_string_literal: true

module Projects
  class KnowledgeRecommendationsController < ApplicationController
    SUPPORTED_ACTIONS = %w[accept dismiss].freeze

    before_action :set_project
    before_action :set_recommendation, only: :update

    def index
      authorize @project, :update?
      load_recommendations
    end

    def update
      authorize @project, :update?

      update_recommendation!
      @update_succeeded = true

      respond_to do |format|
        format.turbo_stream { load_recommendations }
        format.html { redirect_to project_knowledge_recommendations_path(@project) }
      end
    rescue ArgumentError => e
      render_update_error(status: :bad_request, message: e.message)
    rescue ActiveRecord::RecordInvalid => e
      render_update_error(status: :unprocessable_content, message: e.record.errors.full_messages.to_sentence)
    end

    private

    def set_project
      @project = policy_scope(Project).find(params[:project_id])
    end

    def set_recommendation
      @recommendation = @project.knowledge_recommendations.pending.find(params[:id])
    end

    def load_recommendations
      @pending = @project.knowledge_recommendations.pending.by_priority
      @resolved = @project.knowledge_recommendations.where.not(status: "pending").order(created_at: :desc)
    end

    def update_recommendation!
      raise ArgumentError, "Unsupported action type" unless SUPPORTED_ACTIONS.include?(params[:action_type])

      case params[:action_type]
      when "accept"
        @recommendation.accept!
      when "dismiss"
        @recommendation.dismiss!(reason: dismissal_reason_param)
      end
    end

    def render_update_error(status:, message:)
      @update_succeeded = false
      @error_message = message
      load_recommendations

      respond_to do |format|
        format.turbo_stream { render :update, status: status }
        format.html do
          flash.now[:alert] = @error_message
          render :index, status: status
        end
      end
    end

    def dismissal_reason_param
      dismissal_reason = params[:dismissal_reason].to_s.strip
      return dismissal_reason if dismissal_reason.present?

      @recommendation.errors.add(:dismissal_reason, "can't be blank")
      raise ActiveRecord::RecordInvalid, @recommendation
    end
  end
end
