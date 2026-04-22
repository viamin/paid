# frozen_string_literal: true

require "rails_helper"

RSpec.describe "TenantConfigurations" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }

  before { sign_in user }

  describe "GET /tenant_configuration/edit" do
    it "renders the tenant configuration form" do
      get edit_tenant_configuration_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Tenant Configuration")
      expect(response.body).to include("Provider Preferences")
    end
  end

  describe "PATCH /tenant_configuration" do
    it "updates provider, budget, guardrail, quality, agent, and feature settings" do
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")

      patch tenant_configuration_path, params: tenant_configuration_params(api_key)

      expect(response).to redirect_to(edit_tenant_configuration_path)
      setting = account.tenant_setting.reload
      expect(setting.effective_provider_preferences.dig("api_key_ids", "anthropic")).to eq(api_key.id.to_s)
      expect(setting.effective_provider_preferences.dig("model_preferences", "claude")).to eq("claude-sonnet-4-5")
      expect(setting.effective_default_budgets.dig("monthly", "limit_cents")).to eq(2500)
      expect(setting.effective_default_budgets.dig("monthly", "enforcement_mode")).to eq("hard_stop")
      expect(setting.effective_guardrails["max_concurrent_runs"]).to eq(4)
      expect(setting.max_concurrent_runs).to eq(4)
      expect(setting.effective_quality_thresholds["enabled"]).to be(true)
      expect(setting.effective_agent_settings["default_goal"]).to eq("review")
      expect(setting.features["explicit_pr_automation_decisions"]).to be(true)
    end

    it "disables auto-continue when the checkbox submits its hidden false value" do
      account.tenant_setting!.update!(agent_settings: { "auto_continue" => true })

      patch tenant_configuration_path, params: {
        tenant_setting: {
          agent_settings: {
            default_goal: "create_pr",
            auto_continue: "0"
          }
        }
      }

      expect(response).to redirect_to(edit_tenant_configuration_path)
      expect(account.tenant_setting.reload.effective_agent_settings["auto_continue"]).to be(false)
    end

    it "rejects viewers" do
      viewer = create(:user, :viewer, account: account)
      sign_out user
      sign_in viewer

      patch tenant_configuration_path, params: { tenant_setting: { guardrails: { max_concurrent_runs: "2" } } }

      expect(response).to redirect_to(root_path)
    end
  end

  def tenant_configuration_params(api_key)
    {
      tenant_setting: {
        provider_preferences: provider_preferences(api_key),
        default_budgets: default_budgets,
        guardrails: guardrails,
        quality_thresholds: quality_thresholds,
        agent_settings: agent_settings,
        features: { explicit_pr_automation_decisions: "1" }
      }
    }
  end

  def provider_preferences(api_key)
    {
      api_key_ids: { anthropic: api_key.id },
      model_preferences: { claude: "claude-sonnet-4-5" }
    }
  end

  def default_budgets
    {
      monthly: {
        enabled: "1",
        limit_cents: "2500",
        alert_threshold_percent: "80",
        enforcement_mode: "hard_stop",
        grace_buffer_percent: "10"
      }
    }
  end

  def guardrails
    {
      max_concurrent_runs: "4",
      max_tokens_per_run: "100000",
      max_monthly_cost_cents: "2500"
    }
  end

  def quality_thresholds
    {
      enabled: "1",
      composite_score_threshold: "0.75",
      min_recent_runs: "3",
      lookback_window_hours: "24"
    }
  end

  def agent_settings
    {
      default_goal: "review",
      auto_continue: "1"
    }
  end
end
