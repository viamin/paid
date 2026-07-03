# frozen_string_literal: true

require "spec_helper"
require_relative "../../../lib/paid/temporal_worker_config"

RSpec.describe Paid::TemporalWorkerConfig do
  describe ".worker_mode" do
    it "defaults to both" do
      expect(described_class.worker_mode({})).to eq("both")
    end

    it "returns a valid explicit mode" do
      expect(described_class.worker_mode("TEMPORAL_WORKER_MODE" => "poll")).to eq("poll")
    end

    it "rejects an invalid mode" do
      expect {
        described_class.worker_mode("TEMPORAL_WORKER_MODE" => "invalid")
      }.to raise_error(ArgumentError, /Invalid TEMPORAL_WORKER_MODE="invalid"/)
    end
  end

  describe ".selected_activity_slots" do
    let(:slots) do
      {
        agent_activity_slots: 4,
        agent_local_activity_slots: 6,
        poll_activity_slots: 3,
        poll_local_activity_slots: 2
      }
    end

    it "uses only the poll pool in poll mode" do
      expect(described_class.selected_activity_slots(worker_mode: "poll", **slots)).to eq(5)
    end

    it "uses only the agent pool in agent mode" do
      expect(described_class.selected_activity_slots(worker_mode: "agent", **slots)).to eq(10)
    end

    it "sums both pools in both mode" do
      expect(described_class.selected_activity_slots(worker_mode: "both", **slots)).to eq(15)
    end
  end

  describe ".min_required_db_pool" do
    let(:slots) do
      {
        agent_activity_slots: 4,
        agent_local_activity_slots: 6,
        poll_activity_slots: 3,
        poll_local_activity_slots: 2
      }
    end

    it "budgets a second connection per agent activity plus overhead in agent mode" do
      # selected (4 + 6) + heartbeat workers (4) + overhead (2)
      expect(described_class.min_required_db_pool(worker_mode: "agent", **slots)).to eq(16)
    end

    it "budgets heartbeat helper connections for both worker sets plus shared overhead in both mode" do
      # selected (4 + 6 + 3 + 2) + heartbeat workers (4 + 3) + overhead (4)
      expect(described_class.min_required_db_pool(worker_mode: "both", **slots)).to eq(26)
    end

    it "budgets poll heartbeat helper connections in poll mode" do
      # selected (3 + 2) + heartbeat workers (3) + overhead (2)
      expect(described_class.min_required_db_pool(worker_mode: "poll", **slots)).to eq(10)
    end
  end

  describe ".heartbeat_thread_connections" do
    it "reserves one connection per regular activity slot on the selected worker set" do
      expect(described_class.heartbeat_thread_connections(
        worker_mode: "agent",
        agent_activity_slots: 4,
        poll_activity_slots: 3
      )).to eq(4)
      expect(described_class.heartbeat_thread_connections(
        worker_mode: "poll",
        agent_activity_slots: 4,
        poll_activity_slots: 3
      )).to eq(3)
      expect(described_class.heartbeat_thread_connections(
        worker_mode: "both",
        agent_activity_slots: 4,
        poll_activity_slots: 3
      )).to eq(7)
    end
  end
end
