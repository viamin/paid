# frozen_string_literal: true

require "rails_helper"

RSpec.describe "TenantConfigurations" do
  let(:account) { create(:account) }
  let(:user) { create(:user, :owner, account: account) }

  before do
    sign_in user
    FeatureFlags.flipper.features.each(&:remove)
  end

  describe "GET /tenant_configuration/edit" do
    it "renders the tenant configuration form" do
      FeatureFlags.enable_percentage_of_actors(:explicit_pr_automation_decisions, 15)

      get edit_tenant_configuration_path

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Tenant Configuration")
      expect(response.body).to include("Runner Preferences")
      expect(response.body).to include("Percentage of actors")
    end
  end

  describe "PATCH /tenant_configuration" do
    it "updates runner, budget, guardrail, quality, agent, and feature settings" do
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")

      patch tenant_configuration_path, params: tenant_configuration_params(api_key)

      expect(response).to redirect_to(edit_tenant_configuration_path)
      setting = account.tenant_setting.reload
      expect(setting.effective_runner_preferences.dig("api_key_ids", "anthropic")).to eq(api_key.id.to_s)
      expect(setting.effective_runner_preferences.dig("model_preferences", "claude")).to eq("claude-sonnet-4-5")
      expect(setting.effective_default_budgets.dig("monthly", "limit_cents")).to eq(2500)
      expect(setting.effective_default_budgets.dig("monthly", "enforcement_mode")).to eq("hard_stop")
      expect(setting.effective_guardrails["max_concurrent_runs"]).to eq(4)
      expect(setting.max_concurrent_runs).to eq(4)
      expect(setting.effective_quality_thresholds["enabled"]).to be(true)
      expect(setting.effective_agent_settings["default_goal"]).to eq("review")
      expect(setting.features["explicit_pr_automation_decisions"]).to be(true)
    end

    it "records account activity when tenant configuration changes" do
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")

      expect do
        patch tenant_configuration_path, params: tenant_configuration_params(api_key)
      end.to change(AccountActivityEvent, :count).by(1)

      expect(account.account_activity_events.recent.first.action).to eq("tenant_configuration.updated")
    end

    it "updates the tenant marketplace auto-attach override" do
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")

      patch tenant_configuration_path, params: tenant_configuration_params(api_key)

      expect(response).to redirect_to(edit_tenant_configuration_path)
      expect(account.tenant_setting.reload.marketplace_auto_attach_required?).to be(true)
    end

    it "updates feature flag rollout percentages" do
      api_key = create(:provider_api_key, user: user, api_service_type: "anthropic")

      patch tenant_configuration_path, params: tenant_configuration_params(api_key)

      expect(response).to redirect_to(edit_tenant_configuration_path)
      expect(FeatureFlags.rollout_status(:explicit_pr_automation_decisions)).to include(
        percentage_of_actors: 25,
        percentage_of_time: 10
      )
    end

    it "updates tenant-level auto-pick skip labels" do
      patch tenant_configuration_path, params: {
        tenant_setting: {
          auto_pick_skip_labels_override: "1",
          auto_pick_skip_labels_csv: "planning, research"
        }
      }

      expect(response).to redirect_to(edit_tenant_configuration_path)
      expect(account.tenant_setting.reload.auto_pick_skip_labels).to eq(%w[planning research])
    end

    it "allows an empty tenant-level skip-label override" do
      account.tenant_setting!.update!(auto_pick_skip_labels: %w[planning])

      patch tenant_configuration_path, params: {
        tenant_setting: {
          auto_pick_skip_labels_override: "1",
          auto_pick_skip_labels_csv: ""
        }
      }

      expect(response).to redirect_to(edit_tenant_configuration_path)
      expect(account.tenant_setting.reload.auto_pick_skip_labels).to eq([])
    end

    it "clears the tenant-level override when skip labels are not overridden" do
      account.tenant_setting!.update!(auto_pick_skip_labels: %w[planning])

      patch tenant_configuration_path, params: {
        tenant_setting: {
          auto_pick_skip_labels_override: "0",
          auto_pick_skip_labels_csv: "planning, research"
        }
      }

      expect(response).to redirect_to(edit_tenant_configuration_path)
      expect(account.tenant_setting.reload.auto_pick_skip_labels).to be_nil
    end

    it "disables auto-continue when the checkbox submits its hidden false value" do
      account.tenant_setting!.update!(agent_settings: { "auto_continue" => true })

      patch tenant_configuration_path, params: {
        tenant_setting: {
          agent_settings: {
            default_goal: "create_pr",
            auto_continue: "0",
            marketplace_auto_attach_required: "0"
          }
        }
      }

      expect(response).to redirect_to(edit_tenant_configuration_path)
      expect(account.tenant_setting.reload.effective_agent_settings["auto_continue"]).to be(false)
    end

    it "rejects unsupported default agent goals" do
      patch tenant_configuration_path, params: {
        tenant_setting: {
          agent_settings: {
            default_goal: "typo",
            auto_continue: "1",
            marketplace_auto_attach_required: "0"
          }
        }
      }

      expect(response).to have_http_status(:unprocessable_content)
      expect(account.tenant_setting.reload.default_goal).to eq("create_pr")
    end

    it "rejects invalid rollout percentages" do
      patch tenant_configuration_path, params: rollout_params(percentage_of_actors: "101")

      expect(response).to have_http_status(:unprocessable_content)
      expect(FeatureFlags.rollout_status(:explicit_pr_automation_decisions)[:percentage_of_actors]).to eq(0)
    end

    it "rejects admins from modifying feature flag rollouts" do
      admin = create(:user, :admin, account: account)
      sign_out user
      sign_in admin

      patch tenant_configuration_path, params: {
        tenant_setting: { agent_settings: { default_goal: "review", auto_continue: "1", marketplace_auto_attach_required: "0" } },
        feature_flag_rollouts: {
          explicit_pr_automation_decisions: { percentage_of_actors: "50", percentage_of_time: "0" }
        },
        feature_flag_rollout_originals: {
          explicit_pr_automation_decisions: { percentage_of_actors: "0", percentage_of_time: "0" }
        }
      }

      expect(response).to redirect_to(root_path)
      expect(FeatureFlags.rollout_status(:explicit_pr_automation_decisions)[:percentage_of_actors]).to eq(0)
    end

    it "allows admins to update tenant settings without feature flag rollouts" do
      admin = create(:user, :admin, account: account)
      sign_out user
      sign_in admin

      patch tenant_configuration_path, params: {
        tenant_setting: { guardrails: { max_concurrent_runs: "2" } }
      }

      expect(response).to redirect_to(edit_tenant_configuration_path)
      expect(account.tenant_setting.reload.effective_guardrails["max_concurrent_runs"]).to eq(2)
    end

    it "allows admins to submit the form with unchanged rollout values" do
      admin = create(:user, :admin, account: account)
      sign_out user
      sign_in admin

      patch tenant_configuration_path, params: {
        tenant_setting: { guardrails: { max_concurrent_runs: "3" } },
        feature_flag_rollouts: {
          explicit_pr_automation_decisions: { percentage_of_actors: "0", percentage_of_time: "0" }
        },
        feature_flag_rollout_originals: {
          explicit_pr_automation_decisions: { percentage_of_actors: "0", percentage_of_time: "0" }
        }
      }

      expect(response).to redirect_to(edit_tenant_configuration_path)
      expect(account.tenant_setting.reload.effective_guardrails["max_concurrent_runs"]).to eq(3)
    end

    it "does not overwrite rollout changes made by another user since the page was loaded" do
      FeatureFlags.enable_percentage_of_actors(:explicit_pr_automation_decisions, 25)

      patch tenant_configuration_path, params: {
        tenant_setting: { agent_settings: { default_goal: "review", auto_continue: "1", marketplace_auto_attach_required: "0" } },
        feature_flag_rollouts: {
          explicit_pr_automation_decisions: { percentage_of_actors: "0", percentage_of_time: "0" }
        },
        feature_flag_rollout_originals: {
          explicit_pr_automation_decisions: { percentage_of_actors: "0", percentage_of_time: "0" }
        }
      }

      expect(response).to redirect_to(edit_tenant_configuration_path)
      expect(FeatureFlags.rollout_status(:explicit_pr_automation_decisions)[:percentage_of_actors]).to eq(25)
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
        runner_preferences: runner_preferences(api_key),
        default_budgets: default_budgets,
        guardrails: guardrails,
        quality_thresholds: quality_thresholds,
        agent_settings: agent_settings,
        features: { explicit_pr_automation_decisions: "1" }
      },
      feature_flag_rollouts: {
        explicit_pr_automation_decisions: {
          percentage_of_actors: "25",
          percentage_of_time: "10"
        }
      },
      feature_flag_rollout_originals: {
        explicit_pr_automation_decisions: {
          percentage_of_actors: "0",
          percentage_of_time: "0"
        }
      }
    }
  end

  def runner_preferences(api_key)
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
      auto_continue: "1",
      marketplace_auto_attach_required: "1"
    }
  end

  def rollout_params(percentage_of_actors: "0", percentage_of_time: "0")
    {
      tenant_setting: { agent_settings: { default_goal: "review", auto_continue: "1", marketplace_auto_attach_required: "0" } },
      feature_flag_rollouts: {
        explicit_pr_automation_decisions: {
          percentage_of_actors: percentage_of_actors, percentage_of_time: percentage_of_time
        }
      },
      feature_flag_rollout_originals: {
        explicit_pr_automation_decisions: { percentage_of_actors: "0", percentage_of_time: "0" }
      }
    }
  end
end
