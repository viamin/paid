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
  end
end
