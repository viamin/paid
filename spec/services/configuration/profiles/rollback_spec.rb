# frozen_string_literal: true

require "rails_helper"

# @spec CONFIG-PROFILES-008
RSpec.describe Configuration::Profiles::Rollback do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:profile) { Configuration::Profiles::SoloAutomated }

  before do
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
  end

  describe ".call" do
    it "restores the previous settings and records a configuration_profile.reverted event" do
      apply_profile
      applied_event = latest_applied_event
      expect(applied_event.action).to eq("configuration_profile.applied")
      expect(project.reload.auto_pick_enabled).to be true

      result = nil
      aggregate_failures do
        result = described_class.call(applied_event, actor: owner)
        expect(project.reload.auto_pick_enabled).to be false
        reverted = account.account_activity_events.where(action: "configuration_profile.reverted").last
        expect(reverted).not_to be_nil
        expect(reverted.actor).to eq(owner)
        expect(reverted.subject).to eq(project)
        expect(reverted.metadata["profile"]).to eq("revert:solo_automated")
        expect(reverted.metadata["label"]).to eq("Revert solo_automated posture")
        expect(reverted.metadata["changed_fields"]).to include("auto_pick_enabled")
        expect(reverted.metadata["previous_values"]["auto_pick_enabled"]).to be true
        expect(reverted.metadata["applied_values"]["auto_pick_enabled"]).to be false
        expect(reverted.metadata["reverted_from_activity_id"]).to eq(applied_event.id)
        expect(result[:applied_changes]).to include(include(key: "auto_pick_enabled", applied: true))
      end
    end

    it "pairs each reverted event with its originating applied event" do
      apply_profile
      first_apply = latest_applied_event
      described_class.call(first_apply, actor: owner)

      # A second apply/revert cycle on the same project must be distinguishable
      # from the first: each reverted event points at its own originating apply.
      apply_profile
      second_apply = latest_applied_event
      described_class.call(second_apply, actor: owner)

      reverted_events = account.account_activity_events.where(action: "configuration_profile.reverted").order(:id).to_a
      expect(reverted_events.map { |event| event.metadata["reverted_from_activity_id"] })
        .to eq([ first_apply.id, second_apply.id ])
    end

    it "is a no-op (no reverted event) when the project already matches the previous values" do
      apply_profile
      applied_event = latest_applied_event
      described_class.call(applied_event, actor: owner)

      expect {
        result = described_class.call(applied_event, actor: owner)
        expect(result[:applied_changes]).to eq([])
      }.not_to change(AccountActivityEvent.where(action: "configuration_profile.reverted"), :count)
    end

    it "raises when given an activity event that did not apply a profile" do
      other = Accounts::RecordActivity.call(
        account: account, action: "project.settings_changed", subject: project, metadata: {}
      )

      expect { described_class.call(other) }.to raise_error(ArgumentError, /Only configuration-profile applies/)
    end

    it "raises when the activity event lacks recorded previous_values" do
      apply_profile
      applied_event = latest_applied_event
      applied_event.update!(metadata: applied_event.metadata.except("previous_values"))

      expect { described_class.call(applied_event) }
        .to raise_error(ArgumentError, /no recorded previous_values/)
    end

    it "ignores removed legacy settings in previous_values" do
      apply_profile
      applied_event = latest_applied_event
      metadata = applied_event.metadata.deep_dup
      metadata["previous_values"]["pr_aggregation_enabled"] = false
      metadata["applied_values"]["pr_aggregation_enabled"] = true
      metadata["changed_fields"] << "pr_aggregation_enabled"
      applied_event.update!(metadata:)

      expect {
        described_class.call(applied_event, actor: owner)
      }.not_to raise_error
    end

    it "raises when the subject is not a Project" do
      apply_profile
      applied_event = latest_applied_event
      applied_event.update!(subject_type: "Account", subject_id: account.id)

      expect { described_class.call(applied_event) }.to raise_error(ArgumentError, /not a Project/)
    end

    it "raises when given a non-AccountActivityEvent" do
      expect { described_class.call("not-an-event") }.to raise_error(ArgumentError, /AccountActivityEvent/)
    end
  end

  def apply_profile
    plan = Configuration::Profiles::Planner.call(profile:, project:, actor: owner)
    Configuration::Profiles::Applier.call(plan:, project:, actor: owner)
  end

  def latest_applied_event
    account.account_activity_events.where(action: "configuration_profile.applied").last
  end
end
