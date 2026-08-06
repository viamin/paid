# frozen_string_literal: true

require "rails_helper"

class CheckedInObservabilityAssets < Pathname
end

RSpec.describe CheckedInObservabilityAssets, :no_db do # @spec OBSERVABILITY-003 # @spec OBSERVABILITY-004
  it "ships compose, scrape, and alert assets for the current metric surfaces" do
    compose = Rails.root.join("docker-compose.observability.yml").read
    base_compose = Rails.root.join("docker-compose.yml").read
    prometheus = Rails.root.join("prometheus/prometheus.yml").read
    rules = Rails.root.join("prometheus/rules/paid.yml").read
    alertmanager = Rails.root.join("alertmanager/alertmanager.yml").read

    expect(compose).to include("prometheus:", "grafana:", "alertmanager:", "postgres-exporter:", "loki:", "promtail:")
    expect(base_compose).to include("PAID_LOG_FORMAT: json", "RAILS_LOG_TO_STDOUT: \"1\"")
    expect(prometheus).to include("job_name: paid", "metrics_path: /api/metrics", "job_name: paid-temporal-worker")
    expect(rules).to include(
      "PaidMetricsEndpointDown",
      "PaidQueuedRunsBacklog",
      "PaidAgentRunFailureRateHigh",
      "PaidAgentRunDurationP95High"
    )
    expect(alertmanager).to include('receiver: "null"', 'severity="critical"')
  end

  it "ships datasource, dashboard, and log aggregation assets for the current metric surfaces" do
    datasource = Rails.root.join("grafana/provisioning/datasources/prometheus.yml").read
    loki_datasource = Rails.root.join("grafana/provisioning/datasources/loki.yml").read
    dashboards = Rails.root.join("grafana/provisioning/dashboards/dashboards.yml").read
    loki = Rails.root.join("loki/config.yml").read
    promtail = Rails.root.join("promtail/config.yml").read

    expect(datasource).to include("type: prometheus", "url: http://prometheus:9090")
    expect(loki_datasource).to include("type: loki", "url: http://loki:3100")
    expect(dashboards).to include("path: /var/lib/grafana/dashboards")
    expect(loki).to include("schema: v13", "chunks_directory: /loki/chunks")
    expect(promtail).to include("docker_sd_configs:", "compose_service", "url: http://loki:3100/loki/api/v1/push")
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
