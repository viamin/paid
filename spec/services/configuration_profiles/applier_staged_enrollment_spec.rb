# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-008
RSpec.describe ConfigurationProfiles::Applier do
  let(:account) { create(:account) }
  let(:actor) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }

  before do
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
  end

  def apply_solo_automated
    plan = ConfigurationProfiles::Planner.for_profile(project, ConfigurationProfiles::Registry.find(:solo_automated))
    ConfigurationProfiles::Applier.call(project, plan, actor: actor)
  end

  it "exposes the enrollment value for every legacy profile" do
    expect(ConfigurationProfiles::Registry.find(:solo_automated).value_for("staged_closeout_enrollment_enabled")).to be(true)

    (ConfigurationProfiles::Registry.all - [ ConfigurationProfiles::Registry.find(:solo_automated) ]).each do |profile|
      expect(profile.value_for("staged_closeout_enrollment_enabled")).to be(false), "#{profile.key} must pin enrollment off"
    end
  end

  it "snapshots the live enrollment value" do
    expect(ConfigurationProfiles::FieldSet.snapshot(project)["staged_closeout_enrollment_enabled"]).to be(false)

    StagedCloseoutAdoption::Enroll.call(project:, actor: actor, enabled: true)

    expect(ConfigurationProfiles::FieldSet.snapshot(project.reload)["staged_closeout_enrollment_enabled"]).to be(true)
  end

  it "applies the enrollment through the legacy profile plan with reviewer identity" do
    apply_solo_automated

    enrollment = project.reload.staged_closeout_enrollment
    expect(enrollment).to be_enabled
    expect(enrollment.reviewed_by).to eq(actor)
    expect(enrollment.revision).to eq(1)
  end

  it "does not persist the enrollment without an authorized reviewer" do
    plan = ConfigurationProfiles::Planner.for_profile(project, ConfigurationProfiles::Registry.find(:solo_automated))

    expect { described_class.call(project, plan) }
      .to raise_error(StagedCloseoutAdoption::Error, /authorized/)
    expect(project.reload.staged_closeout_enrollment).to be_nil

    unauthorized_actor = create(:user, account:)

    expect { described_class.call(project, plan, actor: unauthorized_actor) }
      .to raise_error(StagedCloseoutAdoption::Error, /authorized/)
    expect(project.reload.staged_closeout_enrollment).to be_nil
  end

  it "restores the prior enrollment value through the legacy rollback" do
    result = apply_solo_automated
    expect(project.reload.staged_closeout_enrollment).to be_enabled

    ConfigurationProfiles::Rollback.call(result.activity, actor: actor)

    expect(project.reload.staged_closeout_enrollment.enabled?).to be(false)
  end

  describe "posture matching" do
    it "counts the enrollment toward the Fully Automatic posture" do
      profile = ConfigurationProfiles::Registry.find(:solo_automated)
      enrollment_change = profile.diff_against(ConfigurationProfiles::FieldSet.snapshot(project.reload))
        .find { |change| change.field == :staged_closeout_enrollment_enabled }

      expect(enrollment_change).to have_attributes(from: false, to: true)
      expect(profile.matches?(profile.values.merge("staged_closeout_enrollment_enabled" => false))).to be(false)
    end

    it "matches Fully Automatic exactly once the profile enrolled the project" do
      apply_solo_automated

      posture = ConfigurationProfiles::PostureDescriber.describe(project.reload)

      expect(posture).to be_exact
      expect(posture.profile.key).to eq(:solo_automated)
      expect(posture.matching_fields).to eq(posture.total_fields)
    end
  end
end
