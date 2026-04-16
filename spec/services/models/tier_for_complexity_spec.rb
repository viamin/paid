# frozen_string_literal: true

require "rails_helper"

RSpec.describe Models::TierForComplexity do
  describe ".call" do
    it "returns nil when complexity is nil" do
      expect(described_class.call(complexity: nil)).to be_nil
    end

    it "returns nil when complexity is non-numeric" do
      expect(described_class.call(complexity: "not-a-number")).to be_nil
    end

    it "maps low complexity to the low tier using defaults" do
      expect(described_class.call(complexity: 1)).to eq("low")
      expect(described_class.call(complexity: 3)).to eq("low")
    end

    it "maps mid complexity to the mid tier using defaults" do
      expect(described_class.call(complexity: 4)).to eq("mid")
      expect(described_class.call(complexity: 7)).to eq("mid")
    end

    it "maps high complexity to the high tier using defaults" do
      expect(described_class.call(complexity: 8)).to eq("high")
      expect(described_class.call(complexity: 10)).to eq("high")
    end

    it "uses provider thresholds when provided" do
      provider = build(:provider, complexity_thresholds: { "low_max" => 5, "mid_max" => 8 })
      expect(described_class.call(complexity: 5, provider: provider)).to eq("low")
      expect(described_class.call(complexity: 6, provider: provider)).to eq("mid")
      expect(described_class.call(complexity: 9, provider: provider)).to eq("high")
    end

    it "prefers project overrides over provider thresholds" do
      provider = build(:provider, complexity_thresholds: { "low_max" => 5, "mid_max" => 8 })
      project = build(:project)
      project.model_preferences = { "complexity_thresholds" => { "low_max" => 1, "mid_max" => 2 } }

      expect(described_class.call(complexity: 3, provider: provider, project: project)).to eq("high")
    end
  end
end
