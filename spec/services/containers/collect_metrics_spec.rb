# frozen_string_literal: true

require "rails_helper"

RSpec.describe Containers::CollectMetrics do
  let(:agent_run) { create(:agent_run, :running, container_id: "container123") }

  let(:docker_stats) do
    {
      "cpu_stats" => {
        "cpu_usage" => { "total_usage" => 500_000_000 },
        "system_cpu_usage" => 10_000_000_000,
        "online_cpus" => 2
      },
      "precpu_stats" => {
        "cpu_usage" => { "total_usage" => 400_000_000 },
        "system_cpu_usage" => 9_000_000_000
      },
      "memory_stats" => {
        "usage" => 2_147_483_648,
        "limit" => 4_294_967_296
      },
      "pids_stats" => {
        "current" => 42
      }
    }
  end

  let(:mock_container) { instance_double(Docker::Container, stats: docker_stats) }

  before do
    allow(Docker::Container).to receive(:get).with("container123").and_return(mock_container)
    allow(mock_container).to receive(:stats).with(stream: false).and_return(docker_stats)
  end

  describe ".call" do
    it "creates a container metric record" do
      expect { described_class.call(agent_run: agent_run) }
        .to change(ContainerMetric, :count).by(1)
    end

    it "records correct CPU percentage" do
      described_class.call(agent_run: agent_run)
      metric = ContainerMetric.last

      # cpu_delta = 100_000_000, system_delta = 1_000_000_000, cpus = 2
      # (100_000_000 / 1_000_000_000) * 2 * 100 = 20.0
      expect(metric.cpu_percent).to eq(20.0)
    end

    it "records correct memory values" do
      described_class.call(agent_run: agent_run)
      metric = ContainerMetric.last

      expect(metric.memory_bytes).to eq(2_147_483_648)
      expect(metric.memory_limit_bytes).to eq(4_294_967_296)
      expect(metric.memory_percent).to eq(50.0)
    end

    it "records pids count" do
      described_class.call(agent_run: agent_run)
      expect(ContainerMetric.last.pids_count).to eq(42)
    end

    it "stores nil pids_count when pids_stats.current is absent" do
      docker_stats["pids_stats"] = {}
      described_class.call(agent_run: agent_run)
      expect(ContainerMetric.last.pids_count).to be_nil
    end

    it "updates agent run summary fields" do
      described_class.call(agent_run: agent_run)
      agent_run.reload

      expect(agent_run.peak_cpu_percent).to eq(20.0)
      expect(agent_run.peak_memory_bytes).to eq(2_147_483_648)
      expect(agent_run.avg_cpu_percent).to eq(20.0)
      expect(agent_run.avg_memory_bytes).to eq(2_147_483_648)
    end

    it "returns nil when agent run has no container_id" do
      agent_run.update_columns(container_id: nil)
      expect(described_class.call(agent_run: agent_run)).to be_nil
    end

    it "returns nil when agent run is not running" do
      agent_run.update_columns(status: "completed")
      expect(described_class.call(agent_run: agent_run)).to be_nil
    end

    it "handles Docker errors gracefully" do
      allow(Docker::Container).to receive(:get).and_raise(Docker::Error::DockerError)
      expect(described_class.call(agent_run: agent_run)).to be_nil
    end

    it "handles missing container gracefully" do
      allow(Docker::Container).to receive(:get).and_raise(Docker::Error::NotFoundError)
      expect(described_class.call(agent_run: agent_run)).to be_nil
    end
  end
end
