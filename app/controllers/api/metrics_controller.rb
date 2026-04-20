# frozen_string_literal: true

module Api
  # Prometheus-compatible metrics endpoint for external monitoring and auto-scaling.
  #
  # Authentication: intentionally unauthenticated. This endpoint is expected to be
  # network-isolated (VPC-internal only) so that only the Prometheus scraper can reach it.
  # If exposed beyond the VPC, set METRICS_TOKEN and scrapers must send
  # Authorization: Bearer <token>.
  class MetricsController < ActionController::API
    before_action :authenticate_metrics_token!, if: -> { ENV["METRICS_TOKEN"].present? }

    # GET /api/metrics
    def show
      render plain: Metrics::PrometheusCollector.call,
             content_type: "text/plain; version=0.0.4; charset=utf-8"
    end

    private

    def authenticate_metrics_token!
      provided = request.authorization&.delete_prefix("Bearer ")
      head :unauthorized unless ActiveSupport::SecurityUtils.secure_compare(provided.to_s, ENV["METRICS_TOKEN"])
    end
  end
end
