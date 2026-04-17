# frozen_string_literal: true

class TrackerConfigurationsController < ApplicationController
  before_action :set_tracker_configuration, only: [ :show, :update, :destroy ]
  skip_after_action :verify_authorized, only: :index

  def index
    @tracker_configurations = policy_scope(TrackerConfiguration).order(created_at: :desc)
    render json: @tracker_configurations
  end

  def show
    authorize @tracker_configuration
    render json: @tracker_configuration
  end

  def create
    @tracker_configuration = build_tracker_configuration
    @tracker_configuration.created_by = current_user
    authorize @tracker_configuration

    if @tracker_configuration.save
      render json: @tracker_configuration, status: :created
    else
      render json: { errors: @tracker_configuration.errors.full_messages }, status: :unprocessable_content
    end
  end

  def update
    authorize @tracker_configuration

    if @tracker_configuration.update(tracker_configuration_params)
      render json: @tracker_configuration
    else
      render json: { errors: @tracker_configuration.errors.full_messages }, status: :unprocessable_content
    end
  end

  def destroy
    authorize @tracker_configuration
    @tracker_configuration.destroy!
    head :no_content
  end

  private

  def set_tracker_configuration
    @tracker_configuration = policy_scope(TrackerConfiguration).find(params[:id])
  end

  def build_tracker_configuration
    configurable = resolve_configurable
    configurable.build_tracker_configuration(tracker_configuration_params)
  end

  def resolve_configurable
    case params.dig(:tracker_configuration, :configurable_type)
    when "Project"
      policy_scope(Project).find(params.dig(:tracker_configuration, :configurable_id))
    when "User"
      current_user
    when "Account"
      current_account
    else
      current_account
    end
  end

  def tracker_configuration_params
    params.require(:tracker_configuration).permit(
      :tracker_type, :base_url, :integration_credential_id, :enabled,
      project_mapping: {}
    )
  end
end
