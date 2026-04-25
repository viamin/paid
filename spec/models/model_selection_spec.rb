# frozen_string_literal: true

require "rails_helper"

RSpec.describe ModelSelection do
  describe "validations" do
    subject { build(:model_selection) }

    it { is_expected.to validate_presence_of(:selector_type) }
    it { is_expected.to validate_inclusion_of(:selector_type).in_array(described_class::SELECTOR_TYPES) }
    it { is_expected.to validate_uniqueness_of(:agent_run_id) }

    it "allows valid escalated_from_tier values" do
      selection = build(:model_selection, escalated_from_tier: "low")
      expect(selection).to be_valid
    end

    it "rejects invalid escalated_from_tier values" do
      selection = build(:model_selection, escalated_from_tier: "invalid")
      expect(selection).not_to be_valid
    end

    it "allows nil escalated_from_tier" do
      selection = build(:model_selection, escalated_from_tier: nil)
      expect(selection).to be_valid
    end
  end

  describe "associations" do
    it { is_expected.to belong_to(:agent_run) }
    it { is_expected.to belong_to(:llm_model) }
  end

  describe "#escalated?" do
    it "returns true when escalated_from_tier is present" do
      selection = build(:model_selection, escalated_from_tier: "low", escalated_reason: "quality_recovery_project")
      expect(selection).to be_escalated
    end

    it "returns false when escalated_from_tier is nil" do
      selection = build(:model_selection, escalated_from_tier: nil)
      expect(selection).not_to be_escalated
    end
  end

  describe ".escalated scope" do
    it "returns only escalated selections" do
      escalated = create(:model_selection, escalated_from_tier: "low", escalated_reason: "quality_recovery_project")
      _normal = create(:model_selection)

      expect(described_class.escalated).to contain_exactly(escalated)
    end
  end
end
