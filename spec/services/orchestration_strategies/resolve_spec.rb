# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrchestrationStrategies::Resolve do
  describe ".call" do
    # The backfill migration seeds system defaults during db:prepare in CI.
    # Clear them here so these examples can control the persisted state.
    before { OrchestrationStrategy.delete_all }

    context "when a persisted system default exists" do
      let!(:strategy) { create(:orchestration_strategy, :review_settings) }

      it "returns the persisted strategy" do
        result = described_class.call(strategy_type: "review_settings")
        expect(result).to eq(strategy)
      end
    end

    context "when an account override exists" do
      let(:account) { create(:account) }
      let!(:account_strategy) do
        create(:orchestration_strategy, :review_settings, account: account)
      end

      before { create(:orchestration_strategy, :review_settings) }

      it "returns the account-level strategy" do
        result = described_class.call(strategy_type: "review_settings", account: account)
        expect(result).to eq(account_strategy)
      end
    end

    context "when no persisted strategy exists" do
      it "returns a fallback strategy built from hardcoded defaults" do
        result = described_class.call(strategy_type: "review_settings")

        expect(result).to be_a(OrchestrationStrategy)
        expect(result).not_to be_persisted
        expect(result.version).to eq(1)
        expect(result.configuration).to eq(OrchestrationStrategies::Defaults.review_settings)
      end

      it "returns nil for unknown strategy types" do
        result = described_class.call(strategy_type: "nonexistent")
        expect(result).to be_nil
      end
    end

    context "when account has no override but system default exists" do
      let!(:system_strategy) { create(:orchestration_strategy, :review_settings) }
      let(:account) { create(:account) }

      it "falls back to the system default" do
        result = described_class.call(strategy_type: "review_settings", account: account)
        expect(result).to eq(system_strategy)
      end
    end
  end
end
