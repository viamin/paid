# frozen_string_literal: true

require "rails_helper"

# @spec MODEL-SELECTION-004
RSpec.describe ModelSelection do
  describe "validations" do
    subject { build(:model_selection) }

    it { is_expected.to validate_presence_of(:selector_type) }
    it { is_expected.to validate_presence_of(:tier) }
    it { is_expected.to validate_inclusion_of(:selector_type).in_array(described_class::SELECTOR_TYPES) }
    it { is_expected.to validate_uniqueness_of(:agent_run_id) }

    it "allows a nil llm_model" do
      selection = build(:model_selection, llm_model: nil, tier: "mid")

      expect(selection).to be_valid
    end

    it "rejects a nil tier" do
      selection = build(:model_selection, tier: nil)

      expect(selection).not_to be_valid
      expect(selection.errors[:tier]).to include("can't be blank")
    end

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
    it { is_expected.to belong_to(:llm_model).optional }
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

  # AUTO-PICK-QUEUE-011 resolves tier feasibility over the whole
  # LlmModel::TIERS catalog rather than over the tiers candidate issues
  # happen to have pinned, so a persisted tier outside that catalog would
  # never be reported infeasible. The catalog is the load-bearing side of
  # that assumption; this keeps it from drifting from the constraint that
  # actually bounds stored tiers.
  # @spec MODEL-SELECTION-004 AUTO-PICK-QUEUE-011
  describe "persisted tier constraint" do
    let(:constraint) do
      ActiveRecord::Base.connection
        .check_constraints(described_class.table_name)
        .find { |check| check.name == "model_selections_tier_check" }
    end

    it "constrains stored tiers to LlmModel::TIERS" do
      expect(constraint).to be_present
      expect(constraint.expression.scan(/'([^']*)'::character varying/).flatten).to eq(LlmModel::TIERS)
    end
  end
end
