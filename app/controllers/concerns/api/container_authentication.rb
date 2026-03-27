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
    PROXY_CREDENTIAL_PREFIX = "paid-run".freeze

    included do
      before_action :validate_container_request
      before_action :set_agent_run
      before_action :verify_proxy_token
    end

    private

    def validate_container_request
      @agent_run_id, @embedded_proxy_token = extract_embedded_proxy_credentials
      @agent_run_id ||= request.headers["X-Agent-Run-Id"]

      render json: { error: "Missing agent run ID" }, status: :unauthorized unless @agent_run_id.present?
    end

    def set_agent_run
      return if performed?

      @agent_run = AgentRun.find_by(id: @agent_run_id)

      render json: { error: "Invalid or inactive agent run" }, status: :forbidden unless @agent_run&.active?
    end

    def verify_proxy_token
      return if performed?

      provided_token = request.headers["X-Proxy-Token"] || @embedded_proxy_token

      unless provided_token.present?
        render(json: { error: "Invalid proxy token" }, status: :forbidden) and return
      end

      stored_token = @agent_run.ensure_proxy_token!

      unless ActiveSupport::SecurityUtils.secure_compare(provided_token, stored_token)
        render json: { error: "Invalid proxy token" }, status: :forbidden
      end
    end

    def extract_embedded_proxy_credentials
      parse_proxy_credential(request.headers["Authorization"]&.delete_prefix("Bearer ")) ||
        parse_proxy_credential(request.headers["X-Goog-Api-Key"])
    end

    def parse_proxy_credential(value)
      match = value.to_s.match(/\A#{PROXY_CREDENTIAL_PREFIX}:(\d+):([0-9a-f]+)\z/i)
      return unless match

      [ match[1], match[2] ]
    end
  end
end
