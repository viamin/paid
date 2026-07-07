# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::TeamCollaborativeProfile do
  describe ".build_plan" do
    it "does not create a UserSetting or TenantSetting row" do
      user = create(:user)

      expect {
        described_class.build_plan(user: user)
      }.not_to change { [ UserSetting.count, TenantSetting.count ] }
    end

    it "plans a single concurrent run and excludes issues labeled for review from auto-pick" do
      user = create(:user)

      plan = described_class.build_plan(user: user)

      expect(plan.changes).to include(
        hash_including(level: :user, attribute: "user_settings.run_concurrency_mode", after: "manual"),
        hash_including(level: :user, attribute: "user_settings.max_concurrent_runs", after: 1),
        hash_including(level: :user, attribute: "user_settings.auto_pick_skip_labels", after: [ "needs-review" ]),
        hash_including(level: :tenant, attribute: "tenant_settings.max_concurrent_runs", after: 3)
      )
    end

    it "reads the current persisted values as before" do
      user = create(:user)
      create(:user_setting, user: user, run_concurrency_mode: "auto")
      create(:tenant_setting, account: user.account, max_concurrent_runs: 20)

      plan = described_class.build_plan(user: user)

      run_concurrency_change = plan.changes.find { |change| change[:attribute] == "user_settings.run_concurrency_mode" }
      tenant_change = plan.changes.find { |change| change[:attribute] == "tenant_settings.max_concurrent_runs" }
      expect(run_concurrency_change[:before]).to eq("auto")
      expect(tenant_change[:before]).to eq(20)
    end

    it "declares a github_app_installed prerequisite and no clarifying questions" do
      plan = described_class.build_plan(user: create(:user))

      expect(plan.prerequisites).to contain_exactly(hash_including(key: "github_app_installed"))
      expect(plan.questions).to be_empty
    end

    it "rejects overrides so an unsupported override is not silently ignored" do
      user = create(:user)

      expect {
        described_class.build_plan(user: user, overrides: { max_concurrent_runs: 5 })
      }.to raise_error(ArgumentError, /does not accept overrides/)
    end

    it "builds the fixed posture when no overrides are given" do
      plan = described_class.build_plan(user: create(:user), overrides: {})

      expect(plan.changes).to include(
        hash_including(attribute: "user_settings.run_concurrency_mode", after: "manual"),
        hash_including(attribute: "user_settings.max_concurrent_runs", after: 1),
        hash_including(attribute: "tenant_settings.max_concurrent_runs", after: 3)
      )
    end
  end
end
