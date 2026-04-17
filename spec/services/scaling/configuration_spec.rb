# frozen_string_literal: true

require "rails_helper"

RSpec.describe Scaling::Configuration do
  describe ".new" do
    it "uses sensible defaults" do
      config = described_class.new

      expect(config.min_workers).to eq(1)
      expect(config.max_workers).to eq(10)
      expect(config.scale_up_queue_ratio).to eq(5.0)
      expect(config.scale_down_queue_ratio).to eq(0.5)
      expect(config.scale_up_utilization).to eq(0.85)
      expect(config.scale_down_utilization).to eq(0.30)
      expect(config.cooldown_period).to eq(120)
      expect(config.scale_up_step).to eq(1)
      expect(config.scale_down_step).to eq(1)
    end

    it "accepts overrides" do
      config = described_class.new(max_workers: 20, cooldown_period: 60)

      expect(config.max_workers).to eq(20)
      expect(config.cooldown_period).to eq(60)
      expect(config.min_workers).to eq(1) # unchanged default
    end

    it "rejects unknown keys" do
      expect { described_class.new(bogus: 42) }
        .to raise_error(ArgumentError, /Unknown configuration keys: bogus/)
    end

    it "is frozen after initialization" do
      config = described_class.new
      expect(config).to be_frozen
    end
  end

  describe "validation" do
    it "rejects negative min_workers" do
      expect { described_class.new(min_workers: -1) }
        .to raise_error(ArgumentError, /min_workers/)
    end

    it "rejects max_workers less than min_workers" do
      expect { described_class.new(min_workers: 5, max_workers: 3) }
        .to raise_error(ArgumentError, /max_workers/)
    end

    it "rejects non-positive scale_up_queue_ratio" do
      expect { described_class.new(scale_up_queue_ratio: 0) }
        .to raise_error(ArgumentError, /scale_up_queue_ratio/)
    end

    it "rejects utilization outside 0.0..1.0" do
      expect { described_class.new(scale_up_utilization: 1.5) }
        .to raise_error(ArgumentError, /scale_up_utilization/)
    end

    it "rejects negative cooldown_period" do
      expect { described_class.new(cooldown_period: -1) }
        .to raise_error(ArgumentError, /cooldown_period/)
    end

    it "allows zero min_workers" do
      config = described_class.new(min_workers: 0)
      expect(config.min_workers).to eq(0)
    end
  end

  describe "#to_h" do
    it "returns all configuration as a hash" do
      config = described_class.new(max_workers: 5)
      hash = config.to_h

      expect(hash).to be_a(Hash)
      expect(hash[:max_workers]).to eq(5)
      expect(hash.keys).to match_array(described_class::VALID_KEYS)
    end
  end
end
