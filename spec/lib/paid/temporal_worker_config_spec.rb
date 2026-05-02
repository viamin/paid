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

    it "adds two connections of overhead for a single worker mode" do
      expect(described_class.min_required_db_pool(worker_mode: "agent", **slots)).to eq(12)
    end

    it "adds four connections of overhead when both worker sets run together" do
      expect(described_class.min_required_db_pool(worker_mode: "both", **slots)).to eq(19)
    end
  end
end
