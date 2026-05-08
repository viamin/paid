# frozen_string_literal: true

require "rails_helper"

RSpec.describe OrchestrationStrategy do
  subject(:strategy) { build(:orchestration_strategy) }

  # The backfill migration seeds system defaults during db:prepare in CI.
  # Clear them here so these examples can create their own fixture rows.
  before { described_class.delete_all }

  describe "associations" do
    it { is_expected.to belong_to(:account).optional }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:strategy_type) }
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_presence_of(:version) }

    it "validates strategy_type inclusion" do
      strategy.strategy_type = "invalid"
      expect(strategy).not_to be_valid
      expect(strategy.errors[:strategy_type]).to include("is not included in the list")
    end

    it "validates configuration is a hash" do
      strategy.configuration = "not a hash"
      expect(strategy).not_to be_valid
      expect(strategy.errors[:configuration]).to include("must be a JSON object")
    end

    it "accepts a valid strategy" do
      expect(strategy).to be_valid
    end
  end

  describe "scopes" do
    let!(:active_system) { create(:orchestration_strategy, :review_settings) }
    let!(:inactive) { create(:orchestration_strategy, :quality_gate, :inactive) }
    let(:account) { create(:account) }
    let!(:account_strategy) { create(:orchestration_strategy, :execution_timeouts, account: account) }

    describe ".active" do
      it "returns only active strategies" do
        expect(described_class.active).to include(active_system, account_strategy)
        expect(described_class.active).not_to include(inactive)
      end
    end

    describe ".system_defaults" do
      it "returns only strategies without an account" do
        expect(described_class.system_defaults).to include(active_system, inactive)
        expect(described_class.system_defaults).not_to include(account_strategy)
      end
    end

    describe ".for_account" do
      it "returns strategies for a specific account" do
        expect(described_class.for_account(account)).to contain_exactly(account_strategy)
      end
    end

    describe ".by_type" do
      it "filters by strategy type" do
        expect(described_class.by_type("review_settings")).to contain_exactly(active_system)
      end
    end
  end

  describe ".active_for" do
    let!(:system_strategy) { create(:orchestration_strategy, :review_settings) }
    let(:account) { create(:account) }

    it "returns the system default when no account override exists" do
      result = described_class.active_for("review_settings", account: account)
      expect(result).to eq(system_strategy)
    end

    it "prefers an account-level override when present" do
      account_override = create(:orchestration_strategy, :review_settings, account: account)
      result = described_class.active_for("review_settings", account: account)
      expect(result).to eq(account_override)
    end

    it "returns the system default without an account argument" do
      result = described_class.active_for("review_settings")
      expect(result).to eq(system_strategy)
    end

    it "returns nil when no strategy exists" do
      result = described_class.active_for("agent_settings")
      expect(result).to be_nil
    end
  end

  describe "#config_value" do
    subject(:strategy) do
      build(:orchestration_strategy, configuration: {
        "enabled" => true,
        "methods" => { "copilot" => { "timeout" => 30 } }
      })
    end

    it "retrieves top-level values" do
      expect(strategy.config_value("enabled")).to be true
    end

    it "retrieves nested values" do
      expect(strategy.config_value("methods", "copilot", "timeout")).to eq(30)
    end

    it "returns nil for missing keys" do
      expect(strategy.config_value("nonexistent")).to be_nil
    end

    it "returns nil for deep missing keys" do
      expect(strategy.config_value("methods", "missing", "key")).to be_nil
    end
  end
end
