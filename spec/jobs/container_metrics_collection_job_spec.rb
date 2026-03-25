# frozen_string_literal: true

require "rails_helper"

RSpec.describe ContainerMetricsCollectionJob do
  let(:agent_run) { create(:agent_run, :running, container_id: "container123") }

  describe "#perform" do
    before do
      allow(Containers::CollectMetrics).to receive(:call).and_return(double)
    end

    it "collects metrics for running agent run" do
      described_class.perform_now(agent_run.id)
      expect(Containers::CollectMetrics).to have_received(:call).with(agent_run: agent_run)
    end

    it "re-enqueues itself for running agent runs" do
      expect {
        described_class.perform_now(agent_run.id)
      }.to have_enqueued_job(described_class).with(agent_run.id, consecutive_failures: 0)
    end

    it "does not collect metrics for finished agent runs" do
      agent_run.update_columns(status: "completed")
      described_class.perform_now(agent_run.id)
      expect(Containers::CollectMetrics).not_to have_received(:call)
    end

    it "does not re-enqueue for finished agent runs" do
      agent_run.update_columns(status: "completed")
      expect {
        described_class.perform_now(agent_run.id)
      }.not_to have_enqueued_job(described_class)
    end

    it "does not collect metrics when container_id is absent" do
      agent_run.update_columns(container_id: nil)
      described_class.perform_now(agent_run.id)
      expect(Containers::CollectMetrics).not_to have_received(:call)
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

    it "tracks consecutive failures and re-enqueues with incremented count" do
      allow(Containers::CollectMetrics).to receive(:call).and_return(nil)
      expect {
        described_class.perform_now(agent_run.id, consecutive_failures: 2)
      }.to have_enqueued_job(described_class).with(agent_run.id, consecutive_failures: 3)
    end

    it "stops re-enqueuing after max consecutive failures" do
      allow(Containers::CollectMetrics).to receive(:call).and_return(nil)
      expect {
        described_class.perform_now(agent_run.id, consecutive_failures: 4)
      }.not_to have_enqueued_job(described_class)
    end

    it "resets failure count on successful collection" do
      expect {
        described_class.perform_now(agent_run.id, consecutive_failures: 3)
      }.to have_enqueued_job(described_class).with(agent_run.id, consecutive_failures: 0)
    end
  end
end
