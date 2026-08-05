# frozen_string_literal: true

require "rails_helper"

class CheckedInObservabilityAssets < Pathname
end

RSpec.describe CheckedInObservabilityAssets, :no_db do # @spec OBSERVABILITY-003
  it "ships compose, scrape, alert, and datasource assets for the current metric surfaces" do
    compose = Rails.root.join("docker-compose.observability.yml").read
    prometheus = Rails.root.join("prometheus/prometheus.yml").read
    rules = Rails.root.join("prometheus/rules/paid.yml").read
    datasource = Rails.root.join("grafana/provisioning/datasources/prometheus.yml").read
    alertmanager = Rails.root.join("alertmanager/alertmanager.yml").read

    expect(compose).to include("prometheus:", "grafana:", "alertmanager:", "postgres-exporter:")
    expect(prometheus).to include("job_name: paid", "metrics_path: /api/metrics", "job_name: paid-temporal-worker")
    expect(rules).to include(
      "PaidMetricsEndpointDown",
      "PaidQueuedRunsBacklog",
      "PaidAgentRunFailureRateHigh",
      "PaidAgentRunDurationP95High"
    )
    expect(datasource).to include("type: prometheus", "url: http://prometheus:9090")
    expect(alertmanager).to include('receiver: "null"', 'severity="critical"')
  end

  it "ships the Grafana dashboard provisioning and application metric panels" do
    dashboards = Rails.root.join("grafana/provisioning/dashboards/dashboards.yml").read

    expect(dashboards).to include("path: /var/lib/grafana/dashboards")
    expect(Rails.root.join("grafana/dashboards/paid-overview.json").read).to include(
      "Agent Run Outcomes",
      "Agent Run Duration p95",
      "Agent Run Tokens",
      "Agent Run Cost"
    )
  end
end
