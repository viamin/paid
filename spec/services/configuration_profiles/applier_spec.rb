# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::Applier do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, auto_pick_enabled: false) }
  let(:actor) { create(:user, account: account) }
  let(:profile) { ConfigurationProfiles::Registry.find(:solo_automated) }

  before do
    # solo_automated enables paid-agent review, which normally requires the
    # paid-code-reviewer GitHub App credential; treat that as external.
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
  end

  describe ".call with a profile plan" do
    it "writes the target values onto the project" do
      plan = ConfigurationProfiles::Planner.for_profile(project, profile)
      described_class.call(project, plan, actor: actor)

      expect(project.reload.auto_pick_enabled).to be true
      expect(project.reload.auto_merge_mode).to eq("all")
      expect(project.adoption_mode).to eq("full_execution")
      expect(project.quality_gates_enabled?).to be false
    end

    it "records an applied activity event with previous_values for rollback" do
      plan = ConfigurationProfiles::Planner.for_profile(project, profile)
      result = described_class.call(project, plan, actor: actor)

      event = result.activity
      expect(event).to be_an(AccountActivityEvent)
      expect(event.action).to eq("configuration_profile.applied")
      expect(event.subject).to eq(project)
      expect(event.actor).to eq(actor)
      expect(event.metadata["profile_key"]).to eq("solo_automated")
      expect(event.metadata["previous_values"]["auto_pick_enabled"]).to be false
      expect(event.metadata["applied_values"]["auto_pick_enabled"]).to be true
      expect(event.metadata["changed_fields"]).to include("auto_pick_enabled")
    end

    it "is a no-op (and records nothing) when the plan is empty" do
      project.update!(auto_add_labels_enabled: true)
      plan = ConfigurationProfiles::Planner.for_values(project, { auto_add_labels_enabled: true }, label: "noop", source: :custom)
      result = described_class.call(project, plan, actor: actor)

      expect(result.changes).to be_empty
      expect(result.activity).to be_nil
    end

    it "rolls back the transaction if save fails" do
      plan = ConfigurationProfiles::Planner.for_values(
        project, { merge_method: "totally_invalid" }, label: "bad", source: :custom
      )
      expect { described_class.call(project, plan, actor: actor) }.to raise_error(ActiveRecord::RecordInvalid)
      expect(account.account_activity_events.where(action: "configuration_profile.applied")).to be_empty
    end
  end
end
