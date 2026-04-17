# frozen_string_literal: true

require "rails_helper"

RSpec.describe TenantSetting do
  describe "associations" do
    it { is_expected.to belong_to(:account) }
  end

  describe "validations" do
    it { is_expected.to validate_numericality_of(:max_concurrent_runs).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(100) }
    it { is_expected.to validate_numericality_of(:max_projects).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(2_147_483_647) }
    it { is_expected.to validate_numericality_of(:max_users).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(2_147_483_647) }
    it { is_expected.to validate_numericality_of(:max_tokens_per_run).only_integer.is_greater_than_or_equal_to(1).is_less_than_or_equal_to(2_147_483_647) }

    it "allows nil max_monthly_cost_cents" do
      setting = build(:tenant_setting, max_monthly_cost_cents: nil)
      expect(setting).to be_valid
    end

    it "validates max_monthly_cost_cents when present" do
      setting = build(:tenant_setting, max_monthly_cost_cents: -1)
      expect(setting).not_to be_valid
    end

    it "validates features is a hash" do
      setting = build(:tenant_setting)
      setting.features = "not a hash"
      expect(setting).not_to be_valid
      expect(setting.errors[:features]).to include("must be a JSON object")
    end

    it "accepts valid features hash" do
      setting = build(:tenant_setting, features: { "beta_enabled" => true })
      expect(setting).to be_valid
    end
  end

  describe "defaults" do
    it "has sensible defaults" do
      setting = described_class.new(account: create(:account))
      expect(setting.max_concurrent_runs).to eq(10)
      expect(setting.max_projects).to eq(50)
      expect(setting.max_users).to eq(25)
      expect(setting.max_tokens_per_run).to eq(10_000_000)
      expect(setting.max_monthly_cost_cents).to be_nil
      expect(setting.allowed_provider_keys).to eq([])
      expect(setting.features).to eq({})
    end
  end
end
