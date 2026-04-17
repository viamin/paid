# frozen_string_literal: true

module Api
  # Prometheus-compatible metrics endpoint for external monitoring and auto-scaling.
  # Bypasses authentication so scrapers can poll without credentials.
  class MetricsController < ActionController::API
    # GET /api/metrics
    def show
      render plain: Metrics::PrometheusCollector.call,
             content_type: "text/plain; version=0.0.4; charset=utf-8"
    end
  end
end
