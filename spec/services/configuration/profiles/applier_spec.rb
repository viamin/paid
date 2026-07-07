# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::Applier do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:profile) { Configuration::Profiles::SoloAutomated }

  let(:plan) { Configuration::Profiles::Planner.call(profile:, project:) }

  describe "#call" do
    it "applies each planned change and persists it" do
      results = described_class.call(plan:, project:, actor: owner)

      expect(project.reload.auto_pick_enabled).to be true
      expect(project.reload.adoption_mode).to eq("full_execution")
      expect(results).not_to be_empty
    end

    it "returns one result per applied change with the documented shape" do
      results = described_class.call(plan:, project:, actor: owner)

      expect(results).to all(include(applied: true))
      expect(results.first).to match(key: String, from: anything, to: anything, applied: true)
      expect(results.map { |result| result[:key] }).to match_array(plan.changes.map(&:key))
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
      expect(result).to eq([])
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
      blocked_plan = Configuration::Profiles::Planner.call(profile: Configuration::Profiles::TeamReviewed, project:)

      expect(blocked_plan).to be_blocked
      expect {
        described_class.call(plan: blocked_plan, project:, actor: owner)
      }.to raise_error(Configuration::Profiles::BlockedError)
    end

    it "refuses to apply when the actor is not authorized" do
      member = create(:user, :member, account:)

      expect {
        described_class.call(plan:, project:, actor: member)
      }.to raise_error(Configuration::Profiles::UnauthorizedError)
    end

    it "is a no-op for a plan with no changes" do
      described_class.call(plan:, project:, actor: owner)
      no_op_plan = Configuration::Profiles::Planner.call(profile:, project:)

      expect(no_op_plan).to be_no_op
      expect {
        result = described_class.call(plan: no_op_plan, project:, actor: owner)
        expect(result).to eq([])
      }.not_to change(AccountActivityEvent, :count)
    end
  end
end
