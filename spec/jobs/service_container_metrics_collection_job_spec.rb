# frozen_string_literal: true

require "rails_helper"

RSpec.describe ServiceContainerMetricsCollectionJob do
  let(:service_container) { create(:service_container, :running, docker_container_id: "container123") }

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
    it "creates a service container metric record for a running service container" do
      expect {
        described_class.perform_now(service_container.id)
      }.to change(ServiceContainerMetric, :count).by(1)
    end

    it "re-enqueues itself for running service containers" do
      expect {
        described_class.perform_now(service_container.id)
      }.to have_enqueued_job(described_class).with(service_container.id, consecutive_failures: 0)
    end

    it "does not collect metrics for stopped service containers" do
      service_container.update_columns(status: "stopped")

      expect {
        described_class.perform_now(service_container.id)
      }.not_to change(ServiceContainerMetric, :count)
    end

    it "does not re-enqueue for stopped service containers" do
      service_container.update_columns(status: "stopped")

      expect {
        described_class.perform_now(service_container.id)
      }.not_to have_enqueued_job(described_class)
    end

    it "does not collect metrics when docker_container_id is absent" do
      service_container.update_columns(docker_container_id: nil)

      expect {
        described_class.perform_now(service_container.id)
      }.not_to change(ServiceContainerMetric, :count)
    end

    it "does not re-enqueue when docker_container_id is absent" do
      service_container.update_columns(docker_container_id: nil)

      expect {
        described_class.perform_now(service_container.id)
      }.not_to have_enqueued_job(described_class)
    end

    it "handles missing service containers gracefully" do
      expect {
        described_class.perform_now(-1)
      }.not_to raise_error
    end

    it "stops re-enqueuing when the container is not found" do
      allow(Docker::Container).to receive(:get).and_raise(Docker::Error::NotFoundError)

      expect {
        described_class.perform_now(service_container.id)
      }.not_to have_enqueued_job(described_class)
    end

    it "tracks consecutive failures and re-enqueues with incremented count" do
      allow(Docker::Container).to receive(:get).and_raise(Docker::Error::DockerError)

      expect {
        described_class.perform_now(service_container.id, consecutive_failures: 2)
      }.to have_enqueued_job(described_class).with(service_container.id, consecutive_failures: 3)
    end

    it "resets failure count on successful collection" do
      expect {
        described_class.perform_now(service_container.id, consecutive_failures: 3)
      }.to have_enqueued_job(described_class).with(service_container.id, consecutive_failures: 0)
    end
  end
end
