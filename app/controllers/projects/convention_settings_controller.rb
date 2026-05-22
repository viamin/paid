# frozen_string_literal: true

module Projects
  class ConventionSettingsController < ApplicationController
    OVERRIDE_ACTIONS = %w[apply dismiss ignore].freeze
    RECOMMENDATION_ACTIONS = %w[apply dismiss].freeze

    before_action :set_project

    def index
      authorize @project, :update?
      load_convention_data
    end

    def update_override
      authorize @project, :update?

      sync_override!
      @update_succeeded = true

      respond_to do |format|
        format.turbo_stream { load_convention_data; render :update }
        format.html { redirect_to project_convention_settings_path(@project) }
      end
    rescue ArgumentError => e
      render_update_error(status: :bad_request, message: e.message)
    rescue ActiveRecord::RecordInvalid => e
      render_update_error(status: :unprocessable_content, message: e.record.errors.full_messages.to_sentence)
    end

    def update_recommendation
      authorize @project, :update?

      set_recommendation
      update_recommendation!
      @update_succeeded = true

      respond_to do |format|
        format.turbo_stream { load_convention_data; render :update }
        format.html { redirect_to project_convention_settings_path(@project) }
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
      @recommendation = @project.project_convention_recommendations.pending.find(params[:id])
    end

    def load_convention_data
      @profile = ProjectConventions::Resolve.profile(project: @project)
      @pending_recommendations = @project.project_convention_recommendations.pending.by_recency
      @resolved_recommendations = @project.project_convention_recommendations.resolved.by_recency
    end

    def sync_override!
      key = params[:key].to_s
      raise ArgumentError, "Key is required" if key.blank?

      override = @project.project_convention_overrides.find_or_initialize_by(key: key)
      override.assign_attributes(
        value: override_value_params,
        mode: override_mode_param,
        enabled: true
      )
      override.save!
    end

    def update_recommendation!
      raise ArgumentError, "Unsupported action type" unless RECOMMENDATION_ACTIONS.include?(params[:action_type])

      case params[:action_type]
      when "apply"
        @recommendation.apply!(applied_by: current_user)
      when "dismiss"
        @recommendation.dismiss!(dismissed_by: current_user, reason: dismissal_reason_param)
      end
    end

    def render_update_error(status:, message:)
      @update_succeeded = false
      @error_message = message
      load_convention_data

      respond_to do |format|
        format.turbo_stream { render :update, status: status }
        format.html do
          flash.now[:alert] = @error_message
          render :index, status: status
        end
      end
    end

    def override_mode_param
      mode = params[:mode].to_s
      raise ArgumentError, "Unsupported mode" unless OVERRIDE_ACTIONS.include?(mode)

      mode
    end

    def override_value_params
      value = params[:value]
      value = JSON.parse(value) if value.is_a?(String)
    rescue JSON::ParserError
      raise ArgumentError, "Value must be a JSON object"
    else
      raise ArgumentError, "Value must be a JSON object" unless value.is_a?(Hash)

      value
    end

    def dismissal_reason_param
      reason = params[:dismissal_reason].to_s.strip
      return reason if reason.present?

      @recommendation.errors.add(:dismissal_reason, "can't be blank")
      raise ActiveRecord::RecordInvalid, @recommendation
    end
  end
end
