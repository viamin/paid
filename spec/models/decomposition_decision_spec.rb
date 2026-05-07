# frozen_string_literal: true

require "rails_helper"

RSpec.describe DecompositionDecision do
  subject(:decomposition_decision) { build(:decomposition_decision) }

  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:issue) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:decision_key) }
    it { is_expected.to validate_uniqueness_of(:decision_key) }
    it { is_expected.to validate_presence_of(:workflow_name) }
    it { is_expected.to validate_presence_of(:workflow_id) }
    it { is_expected.to validate_presence_of(:decision_type) }
    it { is_expected.to validate_presence_of(:outcome) }
    it { is_expected.to validate_inclusion_of(:decision_type).in_array(described_class::DECISION_TYPES) }
  end

  describe "defaults" do
    it "initializes json payload columns to hashes" do
      decision = described_class.new

      expect(decision.input_context).to eq({})
      expect(decision.plan_data).to eq({})
      expect(decision.hints).to eq({})
      expect(decision.error_details).to eq({})
      expect(decision.metadata).to eq({})
    end
  end
end
