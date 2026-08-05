# frozen_string_literal: true

require "rails_helper"

# @spec CONFIG-PROFILES-004
RSpec.describe Configuration::Profiles::Applier do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:profile) { Configuration::Profiles::SoloAutomated }

  let(:plan) { Configuration::Profiles::Planner.call(profile:, project:, actor: owner) }

  describe "#call" do
    it "applies each planned change and persists it" do
      results = described_class.call(plan:, project:, actor: owner)

      expect(project.reload.auto_pick_enabled).to be true
      expect(project.reload.adoption_mode).to eq("full_execution")
      expect(owner.settings.reload.run_concurrency_mode).to eq("auto")
      expect(results.fetch(:applied_changes)).not_to be_empty
    end

    it "returns one result per applied change with the documented shape" do
      results = described_class.call(plan:, project:, actor: owner)

      expect(results.fetch(:skipped_levels)).to eq([])
      expect(results.fetch(:applied_changes)).to all(include(applied: true))
      expect(results.fetch(:applied_changes).first).to match(key: String, from: anything, to: anything, level: String, applied: true)
      expect(results.fetch(:applied_changes).map { |result| result[:key] }).to match_array(plan.changes.map(&:key))
    end

    it "records a single activity event capturing profile and changed fields" do
      expect {
        described_class.call(plan:, project:, actor: owner)
      }.to change(AccountActivityEvent, :count).by(1)

      event = account.account_activity_events.last
      expect(event).to have_attributes(
        action: "project.settings_changed",
        actor: owner,
        subject: project
      )
      expect(event.metadata["profile"]).to eq("solo_automated")
      expect(event.metadata["changed_fields"]).to include("auto_pick_enabled")
    end

    it "is idempotent when re-applying the same plan" do
      described_class.call(plan:, project:, actor: owner)

      result = nil
      expect {
        result = described_class.call(plan:, project:, actor: owner)
      }.not_to change(AccountActivityEvent, :count)
      expect(result).to eq(applied_changes: [], skipped_levels: [])
    end

    it "rolls back the project save when activity recording fails" do
      allow(Accounts::RecordActivity).to receive(:call).and_raise(StandardError, "boom")

      expect {
        described_class.call(plan:, project:, actor: owner)
      }.to raise_error(StandardError, "boom")

      expect(project.reload.auto_pick_enabled).to be false
    end

    it "refuses to apply a blocked plan" do
      allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(false)
      blocked_plan = Configuration::Profiles::Planner.call(profile: Configuration::Profiles::TeamReviewed, project:, actor: owner)

      expect(blocked_plan).to be_blocked
      expect {
        described_class.call(plan: blocked_plan, project:, actor: owner)
      }.to raise_error(Configuration::Profiles::BlockedError)
    end

    it "applies authorized levels and reports skipped unauthorized levels" do
      member = create(:user, :member, account:)
      member.settings.update!(run_concurrency_mode: "auto")
      mixed_scope_plan = Configuration::Profiles::Planner.call(
        profile: Configuration::Profiles::ObserveOnly,
        project:,
        actor: member
      )

      result = described_class.call(plan: mixed_scope_plan, project:, actor: member)

      expect(TenantSetting.exists?(account_id: account.id)).to be(false)
      expect(result.fetch(:applied_changes)).to contain_exactly(
        include(key: "run_concurrency_mode", from: "auto", to: "manual", level: "user", applied: true)
      )
      expect(result.fetch(:skipped_levels)).to contain_exactly(
        include("level" => "project", "reason" => "Not authorized to update project settings"),
        include("level" => "tenant", "reason" => "Not authorized to update tenant settings")
      )
      expect(member.settings.reload.run_concurrency_mode).to eq("manual")
      expect(project.reload.auto_pick_enabled).to be false
    end

    it "does not persist a tenant setting when its value already matches the effective default" do
      expect {
        described_class.call(plan:, project:, actor: owner)
      }.not_to change(TenantSetting, :count)
    end

    it "is a no-op for a plan with no changes" do
      described_class.call(plan:, project:, actor: owner)
      no_op_plan = Configuration::Profiles::Planner.call(profile:, project:, actor: owner)

      expect(no_op_plan).to be_no_op
      expect {
        result = described_class.call(plan: no_op_plan, project:, actor: owner)
        expect(result).to eq(applied_changes: [], skipped_levels: [])
      }.not_to change(AccountActivityEvent, :count)
    end
  end
end
