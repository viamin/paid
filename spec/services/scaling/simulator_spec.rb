# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::Simulator do
  let(:base_time) { Time.current }
  let(:config) { Scaling::Configuration.new(**config_overrides) }
  let(:config_overrides) { { cooldown_period: 0 } }

  def snap(queue_depth:, busy_workers:, offset_seconds:)
    Scaling::MetricsSnapshot.new(
      queue_depth: queue_depth,
      active_workers: 1, # will be overridden by simulator
      busy_workers: busy_workers,
      timestamp: base_time + offset_seconds
    )
  end

  describe ".call" do
    context "with a burst workload" do
      let(:snapshots) do
        [
          snap(queue_depth: 2, busy_workers: 1, offset_seconds: 0),
          snap(queue_depth: 20, busy_workers: 1, offset_seconds: 60),
          snap(queue_depth: 40, busy_workers: 1, offset_seconds: 120),
          snap(queue_depth: 10, busy_workers: 1, offset_seconds: 180),
          snap(queue_depth: 0, busy_workers: 0, offset_seconds: 240)
        ]
      end

      it "scales up during burst and down during calm" do
        result = described_class.call(snapshots: snapshots, config: config)

        expect(result.scale_up_count).to be >= 2
        expect(result.scale_down_count).to be >= 1
        expect(result.peak_workers).to be > 1
        expect(result.decisions.size).to eq(5)
      end
    end

    context "with steady low workload" do
      let(:snapshots) do
        5.times.map do |i|
          snap(queue_depth: 1, busy_workers: 0, offset_seconds: i * 60)
        end
      end

      it "holds at min_workers throughout" do
        result = described_class.call(snapshots: snapshots, config: config)

        expect(result.scale_up_count).to eq(0)
        expect(result.scale_down_count).to eq(0)
        expect(result.peak_workers).to eq(config.min_workers)
      end
    end

    context "with cost tracking" do
      let(:config_overrides) { { cooldown_period: 0, cost_per_worker_hour_cents: 100 } }
      let(:snapshots) do
        # 3 snapshots over 2 hours
        [
          snap(queue_depth: 1, busy_workers: 0, offset_seconds: 0),
          snap(queue_depth: 1, busy_workers: 0, offset_seconds: 3600),
          snap(queue_depth: 1, busy_workers: 0, offset_seconds: 7200)
        ]
      end

      it "estimates cost based on worker-hours" do
        result = described_class.call(snapshots: snapshots, config: config)

        # 1 worker * 100 cents/hr * 1 hr = 100 cents per interval, 2 intervals
        expect(result.total_cost_cents).to eq(200)
      end
    end

    context "with cooldown periods" do
      let(:config_overrides) { { cooldown_period: 90 } }
      let(:snapshots) do
        # Rapid-fire high-queue snapshots, only 30s apart
        6.times.map do |i|
          snap(queue_depth: 50, busy_workers: 1, offset_seconds: i * 30)
        end
      end

      it "limits scaling frequency" do
        result = described_class.call(snapshots: snapshots, config: config)

        # With 90s cooldown and 30s intervals, can only scale every 3rd tick
        expect(result.scale_up_count).to be <= 3
        expect(result.hold_count).to be >= 3
      end
    end

    it "returns comprehensive result struct" do
      snapshots = [
        snap(queue_depth: 50, busy_workers: 1, offset_seconds: 0),
        snap(queue_depth: 0, busy_workers: 0, offset_seconds: 60)
      ]
      result = described_class.call(snapshots: snapshots, config: config)

      expect(result).to respond_to(
        :decisions, :scale_up_count, :scale_down_count, :hold_count,
        :peak_workers, :min_workers_seen, :total_cost_cents, :max_queue_depth
      )
      expect(result.max_queue_depth).to eq(50)
    end
  end
end
