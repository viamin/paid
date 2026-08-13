# frozen_string_literal: true

require "rails_helper"

RSpec.describe TenantConfigurations::ApplyProjectDefaults do
  describe ".call" do
    it "creates project cost budgets from tenant defaults" do
      account = create(:account)
      create(:tenant_setting, account: account, default_budgets: {
        "monthly" => {
          "enabled" => true,
          "limit_cents" => 5_000,
          "alert_threshold_percent" => 70,
          "enforcement_mode" => "hard_stop",
          "grace_buffer_percent" => 15
        }
      })
      project = create(:project, account: account)

      described_class.call(project)

      budget = project.cost_budgets.sole
      expect(budget).to have_attributes(
        budget_type: "monthly",
        limit_cents: 5_000,
        alert_threshold_percent: 70,
        enforcement_mode: "hard_stop",
        grace_buffer_percent: 15
      )
    end

    it "applies tenant quality thresholds when the project has no override" do
      account = create(:account)
      create(:tenant_setting, account: account, quality_thresholds: {
        "enabled" => true,
        "composite_score_threshold" => 0.8,
        "min_recent_runs" => 4,
        "lookback_window_hours" => 12
      })
      project = create(:project, account: account, quality_gate_settings: {})

      described_class.call(project)

      expect(project.reload.quality_gate_settings).to include(
        "enabled" => true,
        "composite_score_threshold" => 0.8,
        "min_recent_runs" => 4,
        "lookback_window_hours" => 12
      )
    end
  end
end
