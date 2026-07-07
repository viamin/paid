# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::SoloFullyAutomatedProfile do
  describe ".build_plan" do
    context "when the user has no persisted settings yet" do
      let(:user) { create(:user) }

      it "does not create a UserSetting or TenantSetting row" do
        expect {
          described_class.build_plan(user: user)
        }.not_to change { [ UserSetting.count, TenantSetting.count ] }
      end

      it "computes before values from in-memory defaults" do
        plan = described_class.build_plan(user: user)

        run_concurrency_change = plan.changes.find { |change| change[:attribute] == "user_settings.run_concurrency_mode" }
        expect(run_concurrency_change[:before]).to eq(UserSetting.new(user: user).run_concurrency_mode)

        tenant_change = plan.changes.find { |change| change[:attribute] == "tenant_settings.max_concurrent_runs" }
        expect(tenant_change[:before]).to eq(TenantSetting.new(account: user.account).max_concurrent_runs)
      end
    end

    context "when the user already has persisted settings" do
      let(:user) { create(:user) }

      it "reads the current persisted values as before" do
        create(:user_setting, user: user, run_concurrency_mode: "manual", max_concurrent_runs: 1)
        create(:tenant_setting, account: user.account, max_concurrent_runs: 2, max_tokens_per_run: 500)

        plan = described_class.build_plan(user: user)

        run_concurrency_change = plan.changes.find { |change| change[:attribute] == "user_settings.run_concurrency_mode" }
        expect(run_concurrency_change[:before]).to eq("manual")
        expect(run_concurrency_change[:after]).to eq("auto")

        tenant_change = plan.changes.find { |change| change[:attribute] == "tenant_settings.max_concurrent_runs" }
        expect(tenant_change[:before]).to eq(2)
        expect(tenant_change[:after]).to eq(10)
      end

      it "plans the permissive skip-label posture advertised by the profile" do
        create(:user_setting, user: user, auto_pick_skip_labels: [ "blocked" ])

        plan = described_class.build_plan(user: user)

        skip_labels_change = plan.changes.find { |change| change[:attribute] == "user_settings.auto_pick_skip_labels" }
        expect(skip_labels_change[:before]).to eq([ "blocked" ])
        expect(skip_labels_change[:after]).to eq([ "needs-design", "blocked-external" ])
      end
    end

    it "applies overrides on top of the profile defaults" do
      user = create(:user)

      plan = described_class.build_plan(user: user, overrides: { max_concurrent_runs: 7 })

      user_change = plan.changes.find { |change| change[:attribute] == "user_settings.max_concurrent_runs" }
      tenant_change = plan.changes.find { |change| change[:attribute] == "tenant_settings.max_concurrent_runs" }
      expect(user_change[:after]).to eq(7)
      expect(tenant_change[:after]).to eq(7)
    end

    it "declares the user and tenant levels only" do
      plan = described_class.build_plan(user: create(:user))

      expect(plan.levels).to contain_exactly(:user, :tenant)
    end

    it "declares a github_app_installed prerequisite" do
      plan = described_class.build_plan(user: create(:user))

      expect(plan.prerequisites).to contain_exactly(
        hash_including(key: "github_app_installed")
      )
    end
  end
end
