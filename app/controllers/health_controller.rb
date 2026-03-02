# frozen_string_literal: true

# Service health check endpoint that bypasses Devise/Pundit authentication.
# Returns aggregate status of infrastructure dependencies.
class HealthController < ActionController::Base
  def show
    qdrant_healthy = Paid.qdrant_client.healthy?

    status = qdrant_healthy ? :ok : :service_unavailable

    render json: {
      status: qdrant_healthy ? "ok" : "degraded",
      services: {
        qdrant: qdrant_healthy ? "ok" : "unavailable"
      }
    }, status: status
  end
end
