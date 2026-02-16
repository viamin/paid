# frozen_string_literal: true

module Api
  # Shared authentication for API endpoints called from agent containers.
  #
  # Validates that requests include a valid agent run ID and proxy token,
  # and that the referenced agent run is currently active.
  #
  # @example
  #   class Api::MyController < ActionController::API
  #     include Api::ContainerAuthentication
  #   end
  module ContainerAuthentication
    extend ActiveSupport::Concern

    included do
      before_action :validate_container_request
      before_action :set_agent_run
      before_action :verify_proxy_token
    end

    private

    def validate_container_request
      @agent_run_id = request.headers["X-Agent-Run-Id"]

      unless @agent_run_id.present?
        render json: { error: "Missing agent run ID" }, status: :unauthorized
      end
    end

    def set_agent_run
      @agent_run = AgentRun.find_by(id: @agent_run_id)

      unless @agent_run&.running?
        render json: { error: "Invalid or inactive agent run" }, status: :forbidden
      end
    end

    def verify_proxy_token
      provided_token = request.headers["X-Proxy-Token"]

      unless provided_token.present?
        render json: { error: "Invalid proxy token" }, status: :forbidden
        return
      end

      stored_token = @agent_run.ensure_proxy_token!

      unless ActiveSupport::SecurityUtils.secure_compare(provided_token, stored_token)
        render json: { error: "Invalid proxy token" }, status: :forbidden
      end
    end
  end
end
