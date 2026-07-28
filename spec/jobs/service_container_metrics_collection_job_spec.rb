# frozen_string_literal: true

require "rails_helper"

RSpec.describe ServiceContainerMetricsCollectionJob do
  let(:service_container) { create(:service_container, :running, docker_container_id: "container123") }

  before do
    allow(Containers::CollectServiceMetrics).to receive(:call).with(service_container: service_container) do
      create(:service_container_metric, service_container: service_container, container_id: service_container.docker_container_id)
    end
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
      allow(Containers::CollectServiceMetrics).to receive(:call).with(service_container: service_container).and_return(:not_found)

      expect {
        described_class.perform_now(service_container.id)
      }.not_to have_enqueued_job(described_class)
    end

    it "tracks consecutive failures and re-enqueues with incremented count" do
      allow(Containers::CollectServiceMetrics).to receive(:call).with(service_container: service_container).and_return(nil)

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
