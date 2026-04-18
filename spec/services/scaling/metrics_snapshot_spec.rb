# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::MetricsSnapshot do
  let(:now) { Time.current }

  describe ".new" do
    it "stores metrics and freezes" do
      snap = described_class.new(
        queue_depth: 10,
        active_workers: 4,
        busy_workers: 3,
        timestamp: now
      )

      expect(snap.queue_depth).to eq(10)
      expect(snap.active_workers).to eq(4)
      expect(snap.busy_workers).to eq(3)
      expect(snap.timestamp).to eq(now)
      expect(snap).to be_frozen
    end

    it "coerces string-like values to integers" do
      snap = described_class.new(queue_depth: "5", active_workers: "2", busy_workers: "1")
      expect(snap.queue_depth).to eq(5)
    end
  end

  describe "validation" do
    it "rejects negative queue_depth" do
      expect { described_class.new(queue_depth: -1, active_workers: 1, busy_workers: 0) }
        .to raise_error(ArgumentError, /queue_depth/)
    end

    it "rejects busy_workers exceeding active_workers" do
      expect { described_class.new(queue_depth: 0, active_workers: 2, busy_workers: 3) }
        .to raise_error(ArgumentError, /busy_workers cannot exceed/)
    end
  end

  describe "#queue_ratio" do
    it "calculates jobs per worker" do
      snap = described_class.new(queue_depth: 12, active_workers: 3, busy_workers: 2)
      expect(snap.queue_ratio).to eq(4.0)
    end

    it "returns 0.0 when queue is empty" do
      snap = described_class.new(queue_depth: 0, active_workers: 3, busy_workers: 0)
      expect(snap.queue_ratio).to eq(0.0)
    end

    it "returns infinity when there are queued jobs but no workers" do
      snap = described_class.new(queue_depth: 5, active_workers: 0, busy_workers: 0)
      expect(snap.queue_ratio).to eq(Float::INFINITY)
    end
  end

  describe "#utilization" do
    it "calculates busy fraction" do
      snap = described_class.new(queue_depth: 0, active_workers: 4, busy_workers: 3)
      expect(snap.utilization).to eq(0.75)
    end

    it "returns 0.0 when no workers are active" do
      snap = described_class.new(queue_depth: 0, active_workers: 0, busy_workers: 0)
      expect(snap.utilization).to eq(0.0)
    end
  end

  describe "#to_h" do
    it "includes computed metrics" do
      snap = described_class.new(queue_depth: 10, active_workers: 2, busy_workers: 1, timestamp: now)
      hash = snap.to_h

      expect(hash[:queue_depth]).to eq(10)
      expect(hash[:utilization]).to eq(0.5)
      expect(hash[:queue_ratio]).to eq(5.0)
      expect(hash[:timestamp]).to eq(now)
    end
  end
end
