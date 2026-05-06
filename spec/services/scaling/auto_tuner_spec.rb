# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::AutoTuner do
  def snapshot(queue_depth:, active_workers:, busy_workers:, timestamp: Time.current)
    Scaling::MetricsSnapshot.new(
      queue_depth: queue_depth,
      active_workers: active_workers,
      busy_workers: busy_workers,
      timestamp: timestamp
    )
  end

  describe ".call" do
    it "returns insufficient_data with too few snapshots" do
      config = Scaling::Configuration.new
      history = 3.times.map { snapshot(queue_depth: 5, active_workers: 2, busy_workers: 1) }

      result = described_class.call(current_config: config, history: history)

      expect(result[:status]).to eq(:insufficient_data)
    end

    it "recommends increasing max_workers under sustained high utilization" do
      config = Scaling::Configuration.new(max_workers: 5, scale_up_utilization: 0.85)
      history = 12.times.map do
        snapshot(queue_depth: 10, active_workers: 5, busy_workers: 5)
      end

      result = described_class.call(current_config: config, history: history)

      expect(result[:status]).to eq(:adjustment_recommended)
      expect(result[:adjustments][:max_workers]).to eq(6)
    end

    it "recommends decreasing max_workers under sustained low utilization" do
      config = Scaling::Configuration.new(max_workers: 10, scale_down_utilization: 0.30)
      history = 12.times.map do
        snapshot(queue_depth: 0, active_workers: 10, busy_workers: 1)
      end

      result = described_class.call(current_config: config, history: history)

      expect(result[:status]).to eq(:adjustment_recommended)
      expect(result[:adjustments][:max_workers]).to eq(9)
    end

    it "recommends increasing scale_up_step on rapid queue growth" do
      config = Scaling::Configuration.new(scale_up_step: 1)
      base_time = Time.current
      history = 12.times.map do |i|
        snapshot(
          queue_depth: (i + 1) * 3,
          active_workers: 3,
          busy_workers: 2,
          timestamp: base_time + i.minutes
        )
      end

      result = described_class.call(current_config: config, history: history)

      expect(result[:adjustments][:scale_up_step]).to eq(2) if result[:adjustments].key?(:scale_up_step)
    end

    it "returns optimal when metrics are within normal ranges" do
      config = Scaling::Configuration.new(max_workers: 10)
      history = 12.times.map do
        snapshot(queue_depth: 2, active_workers: 5, busy_workers: 3)
      end

      result = described_class.call(current_config: config, history: history)

      expect(result[:status]).to eq(:optimal)
      expect(result[:adjustments]).to be_empty
    end

    it "includes summary metrics" do
      config = Scaling::Configuration.new
      history = 12.times.map do
        snapshot(queue_depth: 5, active_workers: 3, busy_workers: 2)
      end

      result = described_class.call(current_config: config, history: history)

      expect(result[:metrics]).to include(
        avg_utilization: be_a(Float),
        avg_queue_depth: be_a(Float),
        max_queue_depth: be_a(Integer),
        sample_count: 12
      )
    end
  end
end
