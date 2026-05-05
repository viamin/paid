# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::QueueMonitor do
  describe ".call" do
    let(:account) { create(:account) }
    let(:project) { create(:project, account: account) }

    before do
      allow(Paid).to receive(:temporal_client).and_raise(StandardError, "Temporal unavailable")
    end

    it "returns a Result with queue depths" do
      result = described_class.call

      expect(result).to be_a(Scaling::QueueMonitor::Result)
      expect(result.queue_depths).to be_an(Array)
      expect(result.alerts).to be_an(Array)
    end

    it "measures GoodJob queue depths" do
      result = described_class.call

      good_job_depths = result.queue_depths.select { |d| d.type == :good_job }
      expect(good_job_depths.map(&:name)).to match_array(
        %w[default maintenance metrics knowledge low_priority]
      )
    end

    it "measures agent run queue depth globally" do
      create(:agent_run, project: project, status: "queued")
      create(:agent_run, project: project, status: "queued")
      create(:agent_run, project: project, status: "queued", temporal_workflow_id: "wf-123")
      create(:agent_run, project: project, status: "running")

      result = described_class.call

      agent_depth = result.queue_depths.find { |d| d.type == :agent_run_queue }
      expect(agent_depth.depth).to eq(2)
    end

    it "scopes agent run queue depth to account when provided" do
      other_account = create(:account)
      other_project = create(:project, account: other_account)

      create(:agent_run, project: project, status: "queued")
      create(:agent_run, project: project, status: "queued", temporal_workflow_id: "wf-123")
      create(:agent_run, project: other_project, status: "queued")

      result = described_class.call(account: account)

      agent_depth = result.queue_depths.find { |d| d.type == :agent_run_queue }
      expect(agent_depth.depth).to eq(1)
    end

    it "reports healthy when all queues are within thresholds" do
      result = described_class.call

      expect(result.healthy?).to be true
      expect(result.alerts).to be_empty
    end

    context "when a queue exceeds the warning threshold" do
      it "generates a warning alert" do
        create(:agent_run, project: project, status: "queued")

        result = described_class.call(thresholds: { agent_run_queue: { warning: 1, critical: 100 } })

        alert = result.alerts.find { |a| a.queue_name == "agent_runs" }
        expect(alert).to be_present
        expect(alert.severity).to eq(:warning)
      end
    end

    context "when a queue exceeds the critical threshold" do
      it "generates a critical alert and marks result unhealthy" do
        create(:agent_run, project: project, status: "queued")

        result = described_class.call(thresholds: { agent_run_queue: { warning: 0, critical: 1 } })

        expect(result.healthy?).to be false
        alert = result.alerts.find { |a| a.queue_name == "agent_runs" }
        expect(alert.severity).to eq(:critical)
      end
    end

    context "when Temporal is unavailable" do
      it "reports Temporal queues with zero depth" do
        result = described_class.call

        temporal_depths = result.queue_depths.select { |d| d.type == :temporal }
        expect(temporal_depths.map(&:name)).to contain_exactly(
          Paid.poll_task_queue, Paid.agent_task_queue
        )
        temporal_depths.each do |depth|
          expect(depth.depth).to eq(0)
          expect(depth.status).to eq(:ok)
        end
      end
    end

    it "uses precomputed_depth when provided instead of querying" do
      create(:agent_run, project: project, status: "queued")

      result = described_class.call(account: account, only: :agent_run_queue, precomputed_depth: 42)

      agent_depth = result.queue_depths.find { |d| d.type == :agent_run_queue }
      expect(agent_depth.depth).to eq(42)
    end

    it "uses a zero precomputed_depth instead of querying" do
      create(:agent_run, project: project, status: "queued")

      result = described_class.call(account: account, only: :agent_run_queue, precomputed_depth: 0)

      agent_depth = result.queue_depths.find { |d| d.type == :agent_run_queue }
      expect(agent_depth.depth).to eq(0)
    end

    it "accepts custom thresholds" do
      result = described_class.call(
        thresholds: { good_job: { warning: 1, critical: 5 } }
      )

      good_job_depth = result.queue_depths.find { |d| d.type == :good_job }
      expect(good_job_depth.threshold_warning).to eq(1)
      expect(good_job_depth.threshold_critical).to eq(5)
    end

    it "skips Temporal queues when skip_temporal is true" do
      result = described_class.call(skip_temporal: true)

      temporal_depths = result.queue_depths.select { |d| d.type == :temporal }
      expect(temporal_depths).to be_empty
    end
  end

  describe ".cached_for_account" do
    let(:account) { create(:account) }
    let(:memory_store) { ActiveSupport::Cache::MemoryStore.new }

    before do
      allow(Paid).to receive(:temporal_client).and_raise(StandardError, "Temporal unavailable")
      allow(Rails).to receive(:cache).and_return(memory_store)
    end

    it "returns cached result when available" do
      original = described_class.call(account: account)
      described_class.write_cache(account, original)

      cached = described_class.cached_for_account(account)

      expect(cached.queue_depths.map(&:name)).to eq(original.queue_depths.map(&:name))
      expect(cached.healthy?).to eq(original.healthy?)
    end

    it "falls back to lightweight result without Temporal on cache miss" do
      allow(Rails).to receive(:cache).and_return(ActiveSupport::Cache::NullStore.new)

      result = described_class.cached_for_account(account)

      expect(result).to be_a(described_class::Result)
      temporal_depths = result.queue_depths.select { |d| d.type == :temporal }
      expect(temporal_depths).to be_empty
      expect(result.queue_depths.select { |d| d.type == :good_job }).not_to be_empty
    end
  end

  describe ".serialize / .deserialize" do
    before do
      allow(Paid).to receive(:temporal_client).and_raise(StandardError, "Temporal unavailable")
    end

    it "round-trips a Result through serialization" do
      original = described_class.call

      deserialized = described_class.deserialize(described_class.serialize(original))

      expect(deserialized.queue_depths.size).to eq(original.queue_depths.size)
      expect(deserialized.alerts.size).to eq(original.alerts.size)
      expect(deserialized.healthy?).to eq(original.healthy?)

      original.queue_depths.each_with_index do |depth, i|
        round_tripped = deserialized.queue_depths[i]
        expect(round_tripped.name).to eq(depth.name)
        expect(round_tripped.type).to eq(depth.type)
        expect(round_tripped.depth).to eq(depth.depth)
        expect(round_tripped.status).to eq(depth.status)
      end
    end
  end
end
