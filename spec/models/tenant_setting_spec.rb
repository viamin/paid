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

    it "validates the default agent goal" do
      setting = build(:tenant_setting, agent_settings: { "default_goal" => "typo" })

      expect(setting).not_to be_valid
      expect(setting.errors[:agent_settings]).to include("default_goal is unsupported")
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
      expect(setting.worker_settings).to eq({})
      expect(setting.self_repo_full_name).to be_nil
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

  describe "#default_goal" do
    it "returns valid tenant goals" do
      setting = build(:tenant_setting, agent_settings: { "default_goal" => "review" })

      expect(setting.default_goal).to eq("review")
    end

    it "falls back when persisted tenant data has an unsupported goal" do
      setting = build(:tenant_setting)
      setting.agent_settings = { "default_goal" => "typo" }

      expect(setting.default_goal).to eq("create_pr")
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

  describe "#auto_pick_skip_labels_csv" do
    it "returns labels as a comma-separated string" do
      setting = build(:tenant_setting, auto_pick_skip_labels: %w[planning research])

      expect(setting.auto_pick_skip_labels_csv).to eq("planning, research")
    end

    it "returns an empty string when labels are not configured" do
      setting = build(:tenant_setting, auto_pick_skip_labels: nil)

      expect(setting.auto_pick_skip_labels_csv).to eq("")
    end
  end

  describe "#auto_pick_skip_labels_csv=" do
    it "parses comma-separated labels into a deduplicated array" do
      setting = build(:tenant_setting)
      setting.auto_pick_skip_labels_csv = " planning, research, planning "

      expect(setting.auto_pick_skip_labels).to eq(%w[planning research])
    end

    it "normalizes labels to lowercase before deduplicating" do
      setting = build(:tenant_setting)
      setting.auto_pick_skip_labels_csv = " Planning, research, PLANNING "

      expect(setting.auto_pick_skip_labels).to eq(%w[planning research])
    end

    it "allows configuring an empty skip-label list" do
      setting = build(:tenant_setting)
      setting.auto_pick_skip_labels_csv = ""

      expect(setting.auto_pick_skip_labels).to eq([])
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

  describe "worker_settings" do
    it "returns defaults when no worker_settings configured" do
      setting = build(:tenant_setting)
      expect(setting.effective_worker_settings).to eq(TenantSetting::DEFAULT_WORKER_SETTINGS)
    end

    it "merges stored values over defaults" do
      setting = build(:tenant_setting, worker_settings: { "temporal_workflow_slots" => 30 })
      expect(setting.effective_worker_settings["temporal_workflow_slots"]).to eq(30)
      expect(setting.effective_worker_settings["temporal_activity_slots"]).to eq(4)
    end

    it "validates integer keys are between 1 and 100" do
      setting = build(:tenant_setting, worker_settings: { "temporal_workflow_slots" => 0 })
      expect(setting).not_to be_valid
      expect(setting.errors[:worker_settings]).to include(match(/must be an integer between 1 and 100/))
    end

    it "validates integer keys do not exceed 100" do
      setting = build(:tenant_setting, worker_settings: { "temporal_activity_slots" => 101 })
      expect(setting).not_to be_valid
    end

    it "validates good_job_queues format" do
      setting = build(:tenant_setting, worker_settings: { "good_job_queues" => "invalid" })
      expect(setting).not_to be_valid
      expect(setting.errors[:worker_settings]).to include(match(/good_job_queues must match format/))
    end

    it "accepts valid good_job_queues" do
      setting = build(:tenant_setting, worker_settings: { "good_job_queues" => "default:3;maintenance:2" })
      expect(setting).to be_valid
    end

    it "normalizes integer values from string input" do
      setting = build(:tenant_setting, worker_settings: { "temporal_workflow_slots" => "25" })
      setting.valid?
      expect(setting.worker_settings["temporal_workflow_slots"]).to eq(25)
    end

    it "provides accessor for individual settings" do
      setting = build(:tenant_setting, worker_settings: { "temporal_workflow_slots" => 30 })
      expect(setting.worker_setting("temporal_workflow_slots")).to eq(30)
    end

    it "returns default for unconfigured individual settings" do
      setting = build(:tenant_setting)
      expect(setting.worker_setting("temporal_workflow_slots")).to eq(20)
    end
  end

  describe "self_repo_full_name" do
    it "accepts valid owner/repo format" do
      setting = build(:tenant_setting, self_repo_full_name: "owner/repo")
      expect(setting).to be_valid
    end

    it "accepts nil" do
      setting = build(:tenant_setting, self_repo_full_name: nil)
      expect(setting).to be_valid
    end

    it "rejects invalid format" do
      setting = build(:tenant_setting, self_repo_full_name: "not-a-repo-format")
      expect(setting).not_to be_valid
      expect(setting.errors[:self_repo_full_name]).to include(match(/must be in owner\/repo format/))
    end
  end

  describe ".resolve_worker_setting" do
    it "returns ENV value when no DB setting exists" do
      result = described_class.resolve_worker_setting(
        "temporal_workflow_slots",
        env_key: "TEMPORAL_WORKFLOW_SLOTS",
        env: { "TEMPORAL_WORKFLOW_SLOTS" => "30" },
        default: 20
      )
      expect(result).to eq(30)
    end

    it "returns default when no DB or ENV setting" do
      result = described_class.resolve_worker_setting(
        "temporal_workflow_slots",
        env_key: "TEMPORAL_WORKFLOW_SLOTS",
        env: {},
        default: 20
      )
      expect(result).to eq(20)
    end

    it "returns DB value when present" do
      account = create(:account)
      create(:tenant_setting, account: account, worker_settings: { "temporal_workflow_slots" => 50 })

      result = TenantContext.with(account) do
        described_class.resolve_worker_setting(
          "temporal_workflow_slots",
          env_key: "TEMPORAL_WORKFLOW_SLOTS",
          env: { "TEMPORAL_WORKFLOW_SLOTS" => "30" },
          default: 20
        )
      end
      expect(result).to eq(50)
    end

    it "handles good_job_queues as string" do
      result = described_class.resolve_worker_setting(
        "good_job_queues",
        env_key: "GOOD_JOB_QUEUES",
        env: { "GOOD_JOB_QUEUES" => "default:5;maintenance:3" },
        default: "default:3;maintenance:2"
      )
      expect(result).to eq("default:5;maintenance:3")
    end
  end
end
