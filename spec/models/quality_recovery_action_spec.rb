# frozen_string_literal: true

require "rails_helper"

RSpec.describe QualityRecoveryAction do
  describe "validations" do
    it { is_expected.to validate_presence_of(:action_type) }
    it { is_expected.to validate_inclusion_of(:action_type).in_array(described_class::ACTION_TYPES) }
    it { is_expected.to validate_presence_of(:status) }
    it { is_expected.to validate_inclusion_of(:status).in_array(described_class::STATUSES) }

    it { is_expected.to validate_numericality_of(:quality_before).is_greater_than_or_equal_to(0).is_less_than_or_equal_to(1).allow_nil }
    it { is_expected.to validate_numericality_of(:quality_after).is_greater_than_or_equal_to(0).is_less_than_or_equal_to(1).allow_nil }
  end

  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:agent_run).optional }
    it { is_expected.to belong_to(:prompt_version).optional }
  end

  describe "#effective?" do
    it "returns true when quality improved" do
      action = build(:quality_recovery_action, quality_before: 0.5, quality_after: 0.8)
      expect(action).to be_effective
    end

    it "returns false when quality did not improve" do
      action = build(:quality_recovery_action, quality_before: 0.8, quality_after: 0.6)
      expect(action).not_to be_effective
    end

    it "returns false when scores are missing" do
      action = build(:quality_recovery_action, quality_before: nil, quality_after: nil)
      expect(action).not_to be_effective
    end
  end

  describe "#quality_delta" do
    it "returns the difference between after and before scores" do
      action = build(:quality_recovery_action, quality_before: 0.5, quality_after: 0.8)
      expect(action.quality_delta).to eq(0.3)
    end

    it "returns nil when scores are missing" do
      action = build(:quality_recovery_action, quality_before: nil, quality_after: nil)
      expect(action.quality_delta).to be_nil
    end
  end

  describe "#execute!" do
    it "sets status to executing and records timestamp" do
      action = create(:quality_recovery_action)
      action.execute!

      expect(action.status).to eq("executing")
      expect(action.executed_at).to be_present
    end
  end

  describe "#complete!" do
    it "sets status to executed with result data" do
      action = create(:quality_recovery_action, :executing)
      action.complete!(status: "rolled_back")

      expect(action.status).to eq("executed")
      expect(action.result).to include("status" => "rolled_back")
    end
  end

  describe "#evaluate!" do
    it "sets quality_after and evaluated_at" do
      action = create(:quality_recovery_action, :executed)
      action.evaluate!(0.85)

      expect(action.status).to eq("evaluated")
      expect(action.quality_after).to eq(0.85)
      expect(action.evaluated_at).to be_present
    end
  end

  describe "#fail!" do
    it "sets status to failed with error data" do
      action = create(:quality_recovery_action, :executing)
      action.fail!(error_class: "RuntimeError", error_message: "boom")

      expect(action.status).to eq("failed")
      expect(action.result["error"]).to include("error_class" => "RuntimeError")
    end
  end

  describe ".effective" do
    it "returns only evaluated actions where quality improved" do
      create(:quality_recovery_action, :evaluated, quality_before: 0.5, quality_after: 0.8)
      create(:quality_recovery_action, :evaluated, quality_before: 0.8, quality_after: 0.6)
      create(:quality_recovery_action, :executed)

      expect(described_class.effective.count).to eq(1)
    end
  end
end
