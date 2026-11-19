# frozen_string_literal: true

require "spec_helper"
require "yaml"
require "json"
require "open3"
require "pathname"
require "tmpdir"

class DevelopmentMemoryMonitoring < Pathname
end

RSpec.describe DevelopmentMemoryMonitoring do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:compose) { YAML.load_file(File.join(root, "docker-compose.memory.yml"), aliases: true) }
  let(:config_root) { File.join(root, "docker/memory-monitoring") }

  # @spec OBSERVABILITY-005
  it "keeps monitoring outside application services and bounds its resource use" do
    services = compose.fetch("services")
    expect(services.keys).not_to include("rails-app", "web", "worker", "postgres")
    services.each_value do |service|
      expect(service.fetch("mem_limit").delete("mgMG").to_i).to be_positive
      expect(service.fetch("cpus").to_f).to be_positive
      expect(Array(service["ports"])).to all(start_with("127.0.0.1:"))
    end
    prometheus = services.fetch("prometheus")
    expect(prometheus.fetch("command")).to include("--storage.tsdb.retention.time=14d", "--storage.tsdb.retention.size=2GB")
    expect(compose.fetch("volumes")).to have_key("prometheus-data")
  end

  # @spec OBSERVABILITY-006
  it "scrapes both workers and lightweight job counts without calling the expensive Rails collector" do
    config = YAML.load_file(File.join(config_root, "prometheus.yml"))
    expect(config.fetch("global").fetch("scrape_interval")).to eq("15s")
    targets = config.fetch("scrape_configs").flat_map { |job| job.fetch("static_configs").flat_map { |row| row.fetch("targets") } }
    expect(targets).to include("paid-rails-app-1:9464", "paid-rails-app-1:9465")
    expect(config.fetch("scrape_configs").map { |job| job["job_name"] }).not_to include("paid")
    queries = YAML.load_file(File.join(config_root, "queries.yml"))
    expect(queries.fetch("paid_goodjob").fetch("query")).to include("WHERE finished_at IS NULL")
    expect(compose.fetch("services").fetch("postgres-exporter").fetch("command")).to include("--no-collector.database")
    process = YAML.load_file(File.join(config_root, "processes.yml"))
    expect(process.fetch("process_names").map { |group| group.fetch("name") }).to eq(%w[paid-puma paid-temporal-workers])
  end

  # @spec OBSERVABILITY-007
  it "shows coverage and incident signals without treating missing metrics as zero" do
    dashboard = JSON.parse(File.read(File.join(config_root, "grafana/dashboards/memory.json")))
    expressions = dashboard.fetch("panels").flat_map { |panel| panel.fetch("targets", []).map { |target| target.fetch("expr") } }
    expect(expressions.join).to include("up", "node_vmstat_oom_kill", "namedprocess_namegroup_memory_bytes")
    expect(dashboard.fetch("description")).to include("cAdvisor", "unavailable")
    expect(expressions.join).not_to match(/or\s+vector\(0\)/)
    expect(dashboard.fetch("timezone")).to eq("utc")
  end

  # @spec OBSERVABILITY-008
  it "refuses activation outside development before contacting Docker or PostgreSQL" do
    stdout, stderr, status = Open3.capture3({ "RAILS_ENV" => nil, "RACK_ENV" => "production" },
      "ruby", File.join(root, "bin/memory-monitoring"), "start")
    expect(status.success?).to be(false)
    expect(stdout + stderr).to include("development only")
  end

  # @spec OBSERVABILITY-005 OBSERVABILITY-008
  it "isolates stop from the application's Compose project and preserves volumes" do
    Dir.mktmpdir("memory-monitoring-cli") do |directory|
      docker = File.join(directory, "docker")
      File.write(docker, "#!/usr/bin/env ruby\nrequire 'json'\nFile.write(ENV.fetch('MEMORY_TEST_ARGUMENTS'), JSON.generate(ARGV))\n")
      File.chmod(0o755, docker)
      arguments = File.join(directory, "arguments.json")
      env = { "RAILS_ENV" => "development", "COMPOSE_PROJECT_NAME" => "paid",
        "PATH" => "#{directory}:#{ENV.fetch('PATH')}", "MEMORY_TEST_ARGUMENTS" => arguments }

      _stdout, stderr, status = Open3.capture3(env, "ruby", File.join(root, "bin/memory-monitoring"), "stop")

      expect(status.success?).to be(true), stderr
      args = JSON.parse(File.read(arguments))
      expect(args.first(4)).to eq(%w[compose --project-name paid-memory --project-directory])
      expect(args.last).to eq("stop")
      expect(args).not_to include("down", "--volumes")
    end
  end
end
