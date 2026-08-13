# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityGateThreshold do
  describe "validations" do
    it "is valid with valid attributes" do
      threshold = build(:quality_gate_threshold)
      expect(threshold).to be_valid
    end

    it "requires metric_key" do
      threshold = build(:quality_gate_threshold, metric_key: nil)
      expect(threshold).not_to be_valid
    end

    it "requires valid metric_key" do
      threshold = build(:quality_gate_threshold, metric_key: "invalid_key")
      expect(threshold).not_to be_valid
    end

    it "requires valid severity" do
      threshold = build(:quality_gate_threshold, severity: "extreme")
      expect(threshold).not_to be_valid
    end

    it "requires at least one threshold" do
      threshold = build(:quality_gate_threshold, min_threshold: nil, max_threshold: nil)
      expect(threshold).not_to be_valid
      expect(threshold.errors[:base]).to include("at least one threshold (min or max) must be set")
    end

    it "enforces uniqueness of metric_key per project" do
      existing = create(:quality_gate_threshold)
      duplicate = build(:quality_gate_threshold,
        project: existing.project, metric_key: existing.metric_key)
      expect(duplicate).not_to be_valid
    end

    it "validates threshold range" do
      threshold = build(:quality_gate_threshold, min_threshold: 1.5)
      expect(threshold).not_to be_valid
    end
  end

  describe "#breached?" do
    let(:threshold) { build(:quality_gate_threshold, min_threshold: 0.5, max_threshold: 0.95) }

    it "returns true when score is below min_threshold" do
      expect(threshold.breached?(0.3)).to be true
    end

    it "returns true when score is above max_threshold" do
      expect(threshold.breached?(0.98)).to be true
    end

    it "returns false when score is within range" do
      expect(threshold.breached?(0.7)).to be false
    end

    it "returns false for nil score" do
      expect(threshold.breached?(nil)).to be false
    end
  end

  describe "#breached_value" do
    let(:threshold) { build(:quality_gate_threshold, min_threshold: 0.5, max_threshold: 0.95) }

    it "returns min_threshold when score is below it" do
      expect(threshold.breached_value(0.3)).to eq(0.5)
    end

    it "returns max_threshold when score is above it" do
      expect(threshold.breached_value(0.98)).to eq(0.95)
    end

    it "returns nil when not breached" do
      expect(threshold.breached_value(0.7)).to be_nil
    end
  end

  describe "scopes" do
    it ".enabled returns only enabled thresholds" do
      enabled = create(:quality_gate_threshold)
      create(:quality_gate_threshold, :disabled, project: create(:project))

      expect(described_class.enabled).to contain_exactly(enabled)
    end

    it ".for_metric filters by metric key" do
      composite = create(:quality_gate_threshold, metric_key: "composite_score")
      create(:quality_gate_threshold, metric_key: "ci_passed", project: create(:project))

      expect(described_class.for_metric("composite_score")).to contain_exactly(composite)
    end
  end
end
