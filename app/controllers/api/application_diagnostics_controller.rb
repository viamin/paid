# frozen_string_literal: true

module Api
  # Read-only diagnostics for the authenticated run only.
  # @spec APP-DIAGNOSTICS-003
  class ApplicationDiagnosticsController < ActionController::API
    include Api::ContainerAuthentication

    CAPTURE_RATE_LIMIT_MAX_REQUESTS = 20
    CAPTURE_RATE_LIMIT_PERIOD = 1.hour

    before_action :ensure_verification_in_progress, only: :capture
    before_action :check_capture_rate_limit, only: :capture

    def show
      render json: AgentRuns::ApplicationDiagnostics.call(
        agent_run: @agent_run,
        lookback_seconds: params[:lookback_seconds],
        limit: params[:limit]
      )
    end

    # @spec APP-DIAGNOSTICS-004
    def capture
      AgentRuns::CaptureApplicationLog.call(agent_run: @agent_run, content: bounded_request_body)
      head :no_content
    rescue AgentRuns::CaptureApplicationLog::TooLargeError => e
      render json: { error: e.message }, status: :payload_too_large
    end

    private

    # @spec APP-DIAGNOSTICS-004
    def ensure_verification_in_progress
      return if @agent_run.active? && @agent_run.verification_applicable?

      render json: { error: "Application log capture is only available while interactive verification is in progress" }, status: :forbidden
    end

    def bounded_request_body
      max_bytes = AgentRuns::CaptureApplicationLog::MAX_LOG_BYTES
      raise AgentRuns::CaptureApplicationLog::TooLargeError, "application log exceeds #{max_bytes} bytes" if request.content_length.to_i > max_bytes

      content = request.body.read(max_bytes + 1)
      raise AgentRuns::CaptureApplicationLog::TooLargeError, "application log exceeds #{max_bytes} bytes" if content.bytesize > max_bytes

      content
    end

    # @spec APP-DIAGNOSTICS-004
    def check_capture_rate_limit
      count = Rails.cache.increment(capture_rate_limit_key, 1, expires_in: CAPTURE_RATE_LIMIT_PERIOD)
      count ||= initialize_capture_rate_limit_count

      return unless count > CAPTURE_RATE_LIMIT_MAX_REQUESTS

      render json: { error: "Application log capture rate limit exceeded" }, status: :too_many_requests
    end

    def initialize_capture_rate_limit_count
      Rails.cache.write(capture_rate_limit_key, 1, expires_in: CAPTURE_RATE_LIMIT_PERIOD)
      1
    end

    def capture_rate_limit_key
      "agent_run:#{@agent_run.id}:application_log_capture_count"
    end
  end
end
