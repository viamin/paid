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

  it "configures the Paid scrape job to send a Bearer token when METRICS_TOKEN is set" do
    # Regression guard for the prometheus/prometheus.yml scrape config: the
    # `paid` job must include an `authorization` block so deployments that
    # set METRICS_TOKEN on the Rails app can still be scraped (otherwise the
    # /api/metrics endpoint returns 401 and the PaidMetricsEndpointDown
    # alert fires on a healthy stack).
    config = YAML.safe_load_file(repo_root.join("prometheus/prometheus.yml"))
    paid_job = config.fetch("scrape_configs").find { |job| job.fetch("job_name") == "paid" }

    authorization = paid_job.fetch("authorization")
    expect(authorization.fetch("type")).to eq("Bearer")
    expect(authorization.fetch("credentials_file")).to eq("/etc/prometheus/metrics_token")
  end

  it "wires the metrics token secret and propagates METRICS_TOKEN to the web service" do
    # Regression guard for the docker-compose wiring: the Prometheus service
    # must mount the token file at the path the scrape config reads from,
    # the top-level `secrets:` block must default to an untracked location
    # (./tmp/prometheus/metrics_token, gitignored via /tmp/*) so a live
    # token never lands in the tracked working tree, and the web service
    # must receive METRICS_TOKEN so the Rails side enforces the same token
    # that Prometheus sends.
    compose = YAML.safe_load_file(repo_root.join("docker-compose.observability.yml"))
    base_compose = YAML.safe_load_file(repo_root.join("docker-compose.yml"))

    prometheus_service = compose.fetch("services").fetch("prometheus")
    prometheus_secrets = prometheus_service.fetch("secrets")
    token_secret = prometheus_secrets.find { |entry| entry.is_a?(Hash) ? entry["source"] == "metrics_token" : entry == "metrics_token" }
    expect(token_secret).not_to be_nil
    expect(token_secret.fetch("target")).to eq("/etc/prometheus/metrics_token")

    secrets_block = compose.fetch("secrets").fetch("metrics_token")
    expect(secrets_block.fetch("file")).to eq("${METRICS_TOKEN_FILE:-./tmp/prometheus/metrics_token}")
    expect(compose.fetch("networks", {})).not_to have_key("paid_internal")

    web_environment = base_compose.fetch("services").fetch("web").fetch("environment")
    expect(web_environment).to have_key("METRICS_TOKEN")
  end

  it "defines alert rules against currently exported metrics" do
    rules = YAML.safe_load_file(repo_root.join("prometheus/rules/paid.yml"))
    alert_names = rules.fetch("groups").flat_map { |group| group.fetch("rules") }.map { |rule| rule.fetch("alert") }

    expect(alert_names).to include(
      "PaidMetricsEndpointDown",
      "PaidQueuedRunsBacklog",
      "PaidGoodJobBacklog",
      "PaidTemporalWorkflowSlotsSaturated",
      "PaidAgentRunFailureRateHigh",
      "PaidAgentRunDurationP95High"
    )
  end

  it "provisions Grafana with a Prometheus datasource and dashboard" do
    datasources = YAML.safe_load_file(repo_root.join("grafana/provisioning/datasources/prometheus.yml"))
    dashboards = YAML.safe_load_file(repo_root.join("grafana/provisioning/dashboards/dashboards.yml"))
    overview = JSON.parse(repo_root.join("grafana/dashboards/paid-overview.json").read)

    expect(datasources.fetch("datasources").first.fetch("uid")).to eq("prometheus")
    expect(dashboards.fetch("providers").first.dig("options", "path")).to eq("/var/lib/grafana/dashboards")
    expect(overview.fetch("uid")).to eq("paid-overview")
    titles = overview.fetch("panels").map { |panel| panel.fetch("title") }

    expect(titles).to include(
      "Agent Run Outcome Rate",
      "Agent Run Duration p95",
      "Agent Run Tokens",
      "Agent Run Cost"
    )
  end

  it "ships a safe default Alertmanager routing config" do
    config = YAML.safe_load_file(repo_root.join("alertmanager/alertmanager.yml"))

    expect(config.fetch("route").fetch("receiver")).to eq("null")
    expect(config.fetch("receivers")).to include(include("name" => "null"))
  end
end
