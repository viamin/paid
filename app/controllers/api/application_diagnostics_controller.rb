# frozen_string_literal: true

module Api
  # Read-only diagnostics for the authenticated run only.
  # @spec APP-DIAGNOSTICS-003
  class ApplicationDiagnosticsController < ActionController::API
    include Api::ContainerAuthentication

    def show
      render json: AgentRuns::ApplicationDiagnostics.call(
        agent_run: @agent_run,
        lookback_seconds: params[:lookback_seconds],
        limit: params[:limit]
      )
    end

    # @spec APP-DIAGNOSTICS-004
    def capture
      AgentRuns::CaptureApplicationLog.call(agent_run: @agent_run, content: request.raw_post)
      head :no_content
    rescue AgentRuns::CaptureApplicationLog::TooLargeError => e
      render json: { error: e.message }, status: :payload_too_large
    end
  end
end
