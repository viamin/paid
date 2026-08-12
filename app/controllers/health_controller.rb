# frozen_string_literal: true

require "redis"
require "timeout"

# Service health check endpoint that bypasses Devise/Pundit authentication.
# Returns aggregate status of infrastructure dependencies.
#
# Endpoints:
# - GET /ready (alias /health/readiness) — readiness probe: DB, Redis, Temporal, Qdrant
# - GET /live  (alias /health/liveness)  — liveness probe (always 200 if process is up)
# - GET /health/services — aggregate health for infrastructure dependencies (legacy)
class HealthController < ActionController::Base
  # Class-level memoized Redis client. Polled by orchestrators every few seconds
  # per pod, so we want to reuse the TCP connection (the redis-rb gem is
  # thread-safe via its built-in mutex) rather than open a fresh handshake on
  # every probe — see ClaudeLoginSessions::Coordination.redis for the same
  # memoized-client pattern. The connection is process-scoped; we deliberately
  # do not close it here because Puma worker lifetime owns the socket and the
  # OS reclaims it on exit.
  def self.redis_client
    @redis_client ||= Redis.new(url: ENV.fetch("REDIS_URL", "redis://127.0.0.1:6379/0"))
  end

  # Readiness probe — returns 200 when the application can serve traffic.
  # Checks database, migrations, Redis, Temporal, and Qdrant (when configured).
  # Orchestrators use this to gate traffic routing and rolling deploys.
  def readiness
    checks = {
      database: database_healthy?,
      migrations: migrations_current?,
      redis: redis_healthy?,
      temporal: temporal_healthy?
    }
    checks[:qdrant] = qdrant_healthy? if qdrant_configured?

    all_healthy = checks.values.all?
    status = all_healthy ? :ok : :service_unavailable

    render json: {
      status: all_healthy ? "ready" : "not_ready",
      checks: checks.transform_values { |v| v ? "ok" : "failing" }
    }, status: status
  end

  # Liveness probe — returns 200 if the Rails process is running.
  # Orchestrators use this to detect hung or crashed processes.
  # A failed liveness probe typically triggers a container restart.
  def liveness
    render json: { status: "alive" }, status: :ok
  end

  # Legacy aggregate health endpoint (Qdrant only).
  # Prefer /ready for a full readiness check.
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

  def redis_healthy?
    Timeout.timeout(redis_timeout) do
      self.class.redis_client.ping == "PONG"
    end
  rescue StandardError
    false
  end

  def temporal_healthy?
    Timeout.timeout(temporal_timeout) do
      Paid.temporal_client.connection.connected?
    end
  rescue StandardError
    false
  end

  def qdrant_healthy?
    Timeout.timeout(qdrant_timeout) do
      Paid.qdrant_client.healthy?
    end
  rescue StandardError
    false
  end

  def qdrant_configured?
    # Mirror Paid.qdrant_api_key's resolution order (credentials first, then
    # QDRANT_API_KEY, then QDRANT_URL). A credentials-only deploy must still
    # surface the Qdrant probe — otherwise /ready would report "ready" while
    # Qdrant is unreachable, defeating the readiness check.
    Rails.application.credentials.dig(:qdrant, :api_key).present? ||
      ENV["QDRANT_URL"].present? ||
      ENV["QDRANT_API_KEY"].present?
  end

  def redis_timeout
    Integer(ENV.fetch("HEALTH_CHECK_REDIS_TIMEOUT", "2"))
  rescue ArgumentError
    2
  end

  def temporal_timeout
    Integer(ENV.fetch("HEALTH_CHECK_TEMPORAL_TIMEOUT", "2"))
  rescue ArgumentError
    2
  end

  def qdrant_timeout
    Integer(ENV.fetch("HEALTH_CHECK_QDRANT_TIMEOUT", "2"))
  rescue ArgumentError
    2
  end
end
