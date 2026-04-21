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

    it "has empty configuration namespace defaults" do
      setting = described_class.new(account: create(:account))
      expect(setting.provider_preferences).to eq({})
      expect(setting.default_budgets).to eq({})
      expect(setting.guardrails).to eq({})
      expect(setting.quality_thresholds).to eq({})
      expect(setting.agent_settings).to eq({})
    end
  end

  describe "#configuration" do
    it "returns effective tenant configuration namespaces" do
      setting = build(:tenant_setting,
        provider_preferences: { "model_preferences" => { "claude" => "sonnet" } },
        guardrails: { "max_concurrent_runs" => 5 },
        features: { "explicit_pr_automation_decisions" => true })

      expect(setting.configuration["provider_preferences"]["model_preferences"]["claude"]).to eq("sonnet")
      expect(setting.configuration["guardrails"]["max_concurrent_runs"]).to eq(5)
      expect(setting.configuration["features"]["explicit_pr_automation_decisions"]).to be(true)
    end
  end

  describe "#default_cost_budget_attributes" do
    it "returns enabled tenant budget defaults" do
      setting = build(:tenant_setting, default_budgets: {
        "daily" => {
          "enabled" => true,
          "limit_cents" => 1_000,
          "alert_threshold_percent" => 75,
          "enforcement_mode" => "hard_stop",
          "grace_buffer_percent" => 10
        }
      })

      expect(setting.default_cost_budget_attributes).to contain_exactly(
        hash_including(
          "budget_type" => "daily",
          "limit_cents" => 1_000,
          "alert_threshold_percent" => 75,
          "enforcement_mode" => "hard_stop",
          "grace_buffer_percent" => 10
        )
      )
    end
  end

  describe "#provider_api_key_for" do
    it "resolves API keys owned by account users" do
      account = create(:account)
      user = create(:user, account: account)
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")
      setting = create(:tenant_setting, account: account,
        provider_preferences: { "api_key_ids" => { "anthropic" => api_key.id } })

      expect(setting.provider_api_key_for("anthropic")).to eq(api_key)
    end
  end
end
