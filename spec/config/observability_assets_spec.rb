# frozen_string_literal: true

require "rails_helper"
require "json"
require "yaml"

module ObservabilityAssets
end

RSpec.describe ObservabilityAssets, :no_db do
  let(:repo_root) { Rails.root }

  it "includes a compose overlay for the observability stack" do
    compose = YAML.safe_load_file(repo_root.join("docker-compose.observability.yml"))

    expect(compose.fetch("services").keys).to include(
      "prometheus",
      "grafana",
      "alertmanager",
      "postgres-exporter",
      "node-exporter",
      "cadvisor"
    )
  end

  it "configures Prometheus to scrape Paid and Temporal worker metrics" do
    config = YAML.safe_load_file(repo_root.join("prometheus/prometheus.yml"))
    jobs = config.fetch("scrape_configs").index_by { |job| job.fetch("job_name") }

    expect(jobs.fetch("paid").fetch("metrics_path")).to eq("/api/metrics")
    expect(jobs.fetch("paid").fetch("static_configs").first.fetch("targets")).to include("web:3000")
    expect(jobs.fetch("paid-temporal-worker").fetch("static_configs").first.fetch("targets")).to include("worker:9464")
  end

  it "defines alert rules against currently exported metrics" do
    rules = YAML.safe_load_file(repo_root.join("prometheus/rules/paid.yml"))
    alert_names = rules.fetch("groups").flat_map { |group| group.fetch("rules") }.map { |rule| rule.fetch("alert") }

    expect(alert_names).to include(
      "PaidMetricsEndpointDown",
      "PaidQueuedRunsBacklog",
      "PaidGoodJobBacklog",
      "PaidTemporalWorkflowSlotsSaturated"
    )
  end

  it "provisions Grafana with a Prometheus datasource and dashboard" do
    datasources = YAML.safe_load_file(repo_root.join("grafana/provisioning/datasources/prometheus.yml"))
    dashboards = YAML.safe_load_file(repo_root.join("grafana/provisioning/dashboards/dashboards.yml"))
    overview = JSON.parse(repo_root.join("grafana/dashboards/paid-overview.json").read)

    expect(datasources.fetch("datasources").first.fetch("uid")).to eq("prometheus")
    expect(dashboards.fetch("providers").first.dig("options", "path")).to eq("/var/lib/grafana/dashboards")
    expect(overview.fetch("uid")).to eq("paid-overview")
    expect(overview.fetch("panels")).not_to be_empty
  end

  it "ships a safe default Alertmanager routing config" do
    config = YAML.safe_load_file(repo_root.join("alertmanager/alertmanager.yml"))

    expect(config.fetch("route").fetch("receiver")).to eq("null")
    expect(config.fetch("receivers")).to include(include("name" => "null"))
  end
end
