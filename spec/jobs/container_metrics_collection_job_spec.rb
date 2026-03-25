# frozen_string_literal: true

require "rails_helper"

RSpec.describe ContainerMetricsCollectionJob do
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
      "pids_stats" => { "current" => 42 }
    }
  end

  let(:mock_container) { instance_double(Docker::Container) }

  before do
    allow(Docker::Container).to receive(:get).with("container123").and_return(mock_container)
    allow(mock_container).to receive(:stats).with(stream: false).and_return(docker_stats)
  end

  describe "#perform" do
    it "creates a container metric record for running agent run" do
      expect {
        described_class.perform_now(agent_run.id)
      }.to change(ContainerMetric, :count).by(1)
    end

    it "updates agent run summary fields" do
      described_class.perform_now(agent_run.id)
      agent_run.reload

      expect(agent_run.peak_cpu_percent).to eq(20.0)
      expect(agent_run.peak_memory_bytes).to eq(2_147_483_648)
    end

    it "re-enqueues itself for running agent runs" do
      expect {
        described_class.perform_now(agent_run.id)
      }.to have_enqueued_job(described_class).with(agent_run.id, consecutive_failures: 0)
    end

    it "does not collect metrics for finished agent runs" do
      agent_run.update_columns(status: "completed")
      expect {
        described_class.perform_now(agent_run.id)
      }.not_to change(ContainerMetric, :count)
    end

    it "does not re-enqueue for finished agent runs" do
      agent_run.update_columns(status: "completed")
      expect {
        described_class.perform_now(agent_run.id)
      }.not_to have_enqueued_job(described_class)
    end

    it "does not collect metrics when container_id is absent" do
      agent_run.update_columns(container_id: nil)
      expect {
        described_class.perform_now(agent_run.id)
      }.not_to change(ContainerMetric, :count)
    end

    it "does not re-enqueue when container_id is absent" do
      agent_run.update_columns(container_id: nil)
      expect {
        described_class.perform_now(agent_run.id)
      }.not_to have_enqueued_job(described_class)
    end

    it "handles missing agent run gracefully" do
      expect {
        described_class.perform_now(-1)
      }.not_to raise_error
    end

    it "tracks consecutive failures when Docker API fails and re-enqueues with incremented count" do
      allow(Docker::Container).to receive(:get).and_raise(Docker::Error::DockerError)
      expect {
        described_class.perform_now(agent_run.id, consecutive_failures: 2)
      }.to have_enqueued_job(described_class).with(agent_run.id, consecutive_failures: 3)
    end

    it "continues re-enqueuing after many consecutive failures with backoff" do
      allow(Docker::Container).to receive(:get).and_raise(Docker::Error::DockerError)
      expect {
        described_class.perform_now(agent_run.id, consecutive_failures: 4)
      }.to have_enqueued_job(described_class).with(agent_run.id, consecutive_failures: 5)
    end

    it "resets failure count on successful collection" do
      expect {
        described_class.perform_now(agent_run.id, consecutive_failures: 3)
      }.to have_enqueued_job(described_class).with(agent_run.id, consecutive_failures: 0)
    end
  end
end
