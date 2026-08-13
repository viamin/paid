# frozen_string_literal: true

require "rails_helper"

RSpec.describe ConfigurationProfiles::Rollback do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account, auto_pick_enabled: false, auto_merge_mode: "off") }
  let(:actor) { create(:user, account: account) }
  let(:profile) { ConfigurationProfiles::Registry.find(:solo_automated) }

  before do
    # solo_automated enables paid-agent review; treat the credential as external.
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
  end

  def apply_profile
    plan = ConfigurationProfiles::Planner.for_profile(project, profile)
    ConfigurationProfiles::Applier.call(project, plan, actor: actor)
  end

  describe ".call" do
    it "restores the previous settings and records a reverted event" do
      applied = apply_profile
      expect(project.reload.auto_pick_enabled).to be true
      expect(project.reload.auto_merge_mode).to eq("all")

      result = described_class.call(applied.activity, actor: actor)

      reverted = result.activity
      expect(reverted.action).to eq("configuration_profile.reverted")
      expect(reverted.metadata["reverted_activity_id"]).to eq(applied.activity.id)
      expect(reverted.metadata["original_profile_key"]).to eq("solo_automated")

      expect(project.reload.auto_pick_enabled).to be false
      expect(project.reload.auto_merge_mode).to eq("off")
    end

    it "raises when given a non-applied activity event" do
      other = Accounts::RecordActivity.call(
        account: account, action: "project.settings_changed", subject: project, metadata: {}
      )
      expect { described_class.call(other) }.to raise_error(ArgumentError, /Only posture applications/)
    end

    it "raises when the activity event lacks recorded previous_values" do
      applied = apply_profile
      applied.activity.update!(metadata: applied.activity.metadata.except("previous_values"))

      expect { described_class.call(applied.activity) }
        .to raise_error(ArgumentError, /no recorded previous_values/)
    end

    it "raises when the subject is not a Project" do
      applied = apply_profile
      applied.activity.update!(subject_type: "Account", subject_id: account.id)

      expect { described_class.call(applied.activity) }.to raise_error(ArgumentError, /not a Project/)
    end
  end
end
