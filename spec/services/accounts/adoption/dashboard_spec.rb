# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::Adoption::Dashboard do
  describe ".call" do
    it "builds adoption analytics from recent activity and enabled capabilities" do
      account, tenant_setting = build_operationalized_account

      result = described_class.call(account: account, tenant_setting: tenant_setting)

      expect(result.dig(:metrics, :active_teams)).to eq(2)
      expect(result.dig(:metrics, :active_projects)).to eq(2)
      expect(result.dig(:metrics, :recent_runs)).to eq(3)
      expect(result.dig(:metrics, :usage_depth, :enabled)).to eq(6)
      expect(result.dig(:metrics, :usage_depth, :total)).to eq(7)
      expect(result.dig(:metrics, :usage_depth, :percentage)).to eq(86)
      expect(result.dig(:metrics, :automation_acceptance_rate)).to eq(50)
      expect(result.dig(:metrics, :manual_override_rate)).to eq(33)
      expect(result.dig(:rollout_stage, :label)).to eq("Operationalized")
    end

    it "surfaces early rollout blockers when the account is not operational yet" do
      account = create(:account)
      tenant_setting = create(:tenant_setting, account: account)

      result = described_class.call(account:, tenant_setting:)

      expect(result.dig(:rollout_stage, :label)).to eq("Setup")
      expect(result[:recommendations]).to include(
        a_hash_including(
          severity: :blocker,
          title: "Connect the first rollout repository"
        )
      )
    end

    def build_operationalized_account
      account = create(:account)
      tenant_setting = create(:tenant_setting, account: account)
      tenant_setting.update!(quality_thresholds: { "enabled" => true }, agent_settings: { "marketplace_auto_attach_required" => true })
      create(:pre_commit_requirement, account: account)
      create(:pr_template, account: account)
      pilot_project = create(:project, account: account, owner: "platform-team", created_by: create(:user, account: account))
      expansion_project = create(:project, account: account, owner: "payments-team", created_by: create(:user, account: account))
      pilot_project.update_column(:auto_pick_enabled, true)
      expansion_project.update_column(:knowledge_evolution_enabled, true)
      create(:agent_run, :completed, project: pilot_project, trigger_type: "automatic", created_at: 3.days.ago)
      create(:agent_run, :failed, project: expansion_project, trigger_type: "automatic", created_at: 2.days.ago)
      create(:agent_run, :completed, project: expansion_project, trigger_type: "manual", created_at: 1.day.ago)
      [ account, tenant_setting ]
    end
  end
end
