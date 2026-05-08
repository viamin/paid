# frozen_string_literal: true

require "rails_helper"

RSpec.describe BundleOutcome do
  describe "associations" do
    it { is_expected.to belong_to(:configuration_bundle) }
    it { is_expected.to belong_to(:agent_run) }
  end

  describe "validations" do
    it { is_expected.to validate_numericality_of(:quality_score).is_greater_than_or_equal_to(0).is_less_than_or_equal_to(1).allow_nil }
    it { is_expected.to validate_numericality_of(:duration_seconds).only_integer.is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:cost_cents).only_integer.is_greater_than_or_equal_to(0).allow_nil }
    it { is_expected.to validate_numericality_of(:tokens_used).only_integer.is_greater_than_or_equal_to(0).allow_nil }

    it "enforces uniqueness of agent_run scoped to configuration_bundle" do
      outcome = create(:bundle_outcome)
      duplicate = build(:bundle_outcome,
        configuration_bundle: outcome.configuration_bundle,
        agent_run: outcome.agent_run)

      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:agent_run_id]).to be_present
    end
  end
end
