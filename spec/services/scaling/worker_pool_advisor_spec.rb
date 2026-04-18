# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::WorkerPoolAdvisor do
  let(:now) { Time.current }
  let(:config) { Scaling::Configuration.new(**config_overrides) }
  let(:config_overrides) { {} }

  def snap(queue_depth:, active_workers:, busy_workers:, timestamp: now)
    Scaling::MetricsSnapshot.new(
      queue_depth: queue_depth,
      active_workers: active_workers,
      busy_workers: busy_workers,
      timestamp: timestamp
    )
  end

  describe ".call" do
    context "when queue ratio exceeds threshold" do
      it "recommends scale_up" do
        # Default scale_up_queue_ratio is 5.0; 18/3 = 6.0 > 5.0
        snapshot = snap(queue_depth: 18, active_workers: 3, busy_workers: 2)
        result = described_class.call(snapshot: snapshot, config: config)

        expect(result.action).to eq(:scale_up)
        expect(result.target_workers).to eq(4)
        expect(result.reason).to include("queue_ratio")
      end
    end

    context "when utilization exceeds threshold" do
      let(:config_overrides) { { max_workers: 20 } }

      it "recommends scale_up" do
        # Default scale_up_utilization is 0.85; 9/10 = 0.9 > 0.85
        snapshot = snap(queue_depth: 0, active_workers: 10, busy_workers: 9)
        result = described_class.call(snapshot: snapshot, config: config)

        expect(result.action).to eq(:scale_up)
        expect(result.target_workers).to eq(11)
        expect(result.reason).to include("utilization")
      end
    end

    context "when both queue and utilization are below thresholds" do
      it "recommends scale_down" do
        # queue_ratio = 0/5 = 0.0 < 0.5; utilization = 1/5 = 0.2 < 0.3
        snapshot = snap(queue_depth: 0, active_workers: 5, busy_workers: 1)
        result = described_class.call(snapshot: snapshot, config: config)

        expect(result.action).to eq(:scale_down)
        expect(result.target_workers).to eq(4)
      end
    end

    context "when metrics are within thresholds" do
      it "recommends hold" do
        # queue_ratio = 6/3 = 2.0 (between 0.5 and 5.0); utilization = 2/3 = 0.67
        snapshot = snap(queue_depth: 6, active_workers: 3, busy_workers: 2)
        result = described_class.call(snapshot: snapshot, config: config)

        expect(result.action).to eq(:hold)
        expect(result.target_workers).to eq(3)
      end
    end

    context "when there are zero workers and jobs queued" do
      let(:config_overrides) { { min_workers: 0 } }

      it "recommends scale_up (infinite queue ratio)" do
        snapshot = snap(queue_depth: 5, active_workers: 0, busy_workers: 0)
        result = described_class.call(snapshot: snapshot, config: config)

        expect(result.action).to eq(:scale_up)
        expect(result.target_workers).to eq(1)
      end
    end

    context "when already at max_workers" do
      let(:config_overrides) { { max_workers: 3 } }

      it "holds despite high queue ratio" do
        snapshot = snap(queue_depth: 30, active_workers: 3, busy_workers: 3)
        result = described_class.call(snapshot: snapshot, config: config)

        expect(result.action).to eq(:hold)
        expect(result.target_workers).to eq(3)
        expect(result.reason).to include("constrained")
      end
    end

    context "when already at min_workers" do
      it "holds despite low utilization" do
        snapshot = snap(queue_depth: 0, active_workers: 1, busy_workers: 0)
        result = described_class.call(snapshot: snapshot, config: config)

        expect(result.action).to eq(:hold)
        expect(result.target_workers).to eq(1)
      end
    end
  end

  describe "cooldown enforcement" do
    it "holds when last scaling was recent" do
      snapshot = snap(queue_depth: 50, active_workers: 2, busy_workers: 2)
      result = described_class.call(
        snapshot: snapshot,
        config: config,
        last_scaled_at: now - 30 # 30 seconds ago, default cooldown is 120s
      )

      expect(result.action).to eq(:hold)
      expect(result.reason).to include("cooldown")
    end

    it "allows scaling after cooldown elapses" do
      snapshot = snap(queue_depth: 50, active_workers: 2, busy_workers: 2)
      result = described_class.call(
        snapshot: snapshot,
        config: config,
        last_scaled_at: now - 200 # 200 seconds ago > 120s cooldown
      )

      expect(result.action).to eq(:scale_up)
    end
  end

  describe "cost constraint enforcement" do
    let(:config_overrides) do
      {
        cost_per_worker_hour_cents: 100,
        max_hourly_cost_cents: 500,
        max_workers: 20
      }
    end

    it "caps workers to what the budget allows" do
      # Budget allows 500/100 = 5 workers max
      snapshot = snap(queue_depth: 100, active_workers: 5, busy_workers: 5)
      result = described_class.call(snapshot: snapshot, config: config)

      expect(result.action).to eq(:hold)
      expect(result.target_workers).to eq(5)
      expect(result.reason).to include("cost limit")
    end

    it "allows scaling within budget" do
      snapshot = snap(queue_depth: 50, active_workers: 3, busy_workers: 3)
      result = described_class.call(snapshot: snapshot, config: config)

      expect(result.action).to eq(:scale_up)
      expect(result.target_workers).to eq(4)
    end
  end

  describe "scale_up_step and scale_down_step" do
    let(:config_overrides) { { scale_up_step: 3, scale_down_step: 2, max_workers: 20 } }

    it "scales up by configured step" do
      snapshot = snap(queue_depth: 50, active_workers: 4, busy_workers: 4)
      result = described_class.call(snapshot: snapshot, config: config)

      expect(result.action).to eq(:scale_up)
      expect(result.target_workers).to eq(7)
    end

    it "scales down by configured step" do
      snapshot = snap(queue_depth: 0, active_workers: 8, busy_workers: 1)
      result = described_class.call(snapshot: snapshot, config: config)

      expect(result.action).to eq(:scale_down)
      expect(result.target_workers).to eq(6)
    end
  end

  describe "predictive trend detection" do
    let(:config_overrides) { { scale_up_queue_ratio: 10.0 } }

    it "pre-scales when queue depth is rising consistently" do
      # Build a rising history that projects past the threshold
      history = [
        snap(queue_depth: 10, active_workers: 4, busy_workers: 2, timestamp: now - 40),
        snap(queue_depth: 20, active_workers: 4, busy_workers: 2, timestamp: now - 30),
        snap(queue_depth: 30, active_workers: 4, busy_workers: 3, timestamp: now - 20),
        snap(queue_depth: 35, active_workers: 4, busy_workers: 3, timestamp: now - 10)
      ]
      # Current: queue_ratio = 38/4 = 9.5, below threshold of 10.0
      # But trend projects to ~63 next -> ratio ~15.75 > 10.0
      current = snap(queue_depth: 38, active_workers: 4, busy_workers: 3)

      result = described_class.call(snapshot: current, config: config, history: history)
      expect(result.action).to eq(:scale_up)
      expect(result.reason).to include("trend")
    end

    it "does not pre-scale when queue is stable" do
      history = [
        snap(queue_depth: 5, active_workers: 4, busy_workers: 2, timestamp: now - 30),
        snap(queue_depth: 5, active_workers: 4, busy_workers: 2, timestamp: now - 20),
        snap(queue_depth: 5, active_workers: 4, busy_workers: 2, timestamp: now - 10)
      ]
      current = snap(queue_depth: 5, active_workers: 4, busy_workers: 2)

      result = described_class.call(snapshot: current, config: config, history: history)
      expect(result.action).to eq(:hold)
    end
  end

  describe "decision struct" do
    it "includes metrics snapshot data" do
      snapshot = snap(queue_depth: 6, active_workers: 3, busy_workers: 2)
      result = described_class.call(snapshot: snapshot, config: config)

      expect(result.metrics).to include(
        queue_depth: 6,
        active_workers: 3,
        busy_workers: 2
      )
    end
  end
end
