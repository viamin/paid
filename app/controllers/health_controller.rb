# frozen_string_literal: true

# Service health check endpoint that bypasses Devise/Pundit authentication.
# Returns aggregate status of infrastructure dependencies.
#
# Endpoints:
# - GET /health/services — aggregate health for infrastructure dependencies
# - GET /health/liveness — minimal liveness probe (always 200 if process is up)
# - GET /health/readiness — readiness probe checking database connectivity
class HealthController < ActionController::Base
  def show
    qdrant_healthy = begin
      Paid.qdrant_client.healthy?
    rescue StandardError
      false
    end

    status = qdrant_healthy ? :ok : :service_unavailable

    render json: {
      status: qdrant_healthy ? "ok" : "degraded",
      services: {
        qdrant: qdrant_healthy ? "ok" : "unavailable"
      }
    }, status: status
  end

  # Liveness probe — returns 200 if the Rails process is running.
  # Orchestrators use this to detect hung or crashed processes.
  # A failed liveness probe typically triggers a container restart.
  def liveness
    render json: { status: "alive" }, status: :ok
  end

  # Readiness probe — returns 200 when the application can serve traffic.
  # Checks database connectivity to ensure the instance is ready to
  # accept work. Orchestrators use this to gate traffic routing.
  def readiness
    checks = {
      database: database_healthy?,
      migrations: migrations_current?
    }

    all_healthy = checks.values.all?
    status = all_healthy ? :ok : :service_unavailable

    render json: {
      status: all_healthy ? "ready" : "not_ready",
      checks: checks.transform_values { |v| v ? "ok" : "failing" }
    }, status: status
  end

  private

  def database_healthy?
    ActiveRecord::Base.connection.execute("SELECT 1")
    true
  rescue StandardError
    false
  end

  def migrations_current?
    ActiveRecord::Migration.check_all_pending!
    true
  rescue StandardError
    false
  end
end
