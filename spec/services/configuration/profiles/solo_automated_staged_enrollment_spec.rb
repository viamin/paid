# frozen_string_literal: true

require "rails_helper"

# @spec STAGED-CLOSEOUT-ADOPTION-008
RSpec.describe Configuration::Profiles::SoloAutomated do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:project) { create(:project, account:) }
  let(:profile) { described_class }

  before do
    allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
  end

  def plan_for(actor: owner)
    Configuration::Profiles::Planner.call(profile:, project:, actor:)
  end

  describe "planning" do
    it "shows the enrollment change for an existing project with the setting off" do
      change = plan_for.changes.find { |candidate| candidate.key == "staged_closeout_enrollment_enabled" }

      expect(change).to have_attributes(from: false, to: true, level: :project)
    end

    it "reports no enrollment change when the project is already enrolled" do
      StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)

      expect(plan_for.changes.map(&:key)).not_to include("staged_closeout_enrollment_enabled")
    end
  end

  describe "applying through the authorized profile workflow" do
    it "turns enrollment on with reviewer identity and revision history" do
      Configuration::Profiles::Applier.call(plan: plan_for, project:, actor: owner)

      enrollment = project.reload.staged_closeout_enrollment
      expect(enrollment).to be_enabled
      expect(enrollment.reviewed_by).to eq(owner)
      expect(enrollment.reviewed_at).to be_present
      expect(enrollment.revision).to eq(1)
    end

    it "records the enrollment change in the applied activity event" do
      Configuration::Profiles::Applier.call(plan: plan_for, project:, actor: owner)

      event = account.account_activity_events.last
      expect(event.action).to eq("configuration_profile.applied")
      expect(event.metadata["changed_fields"]).to include("staged_closeout_enrollment_enabled")
      expect(event.metadata["previous_values"]["staged_closeout_enrollment_enabled"]).to be false
      expect(event.metadata["applied_values"]["staged_closeout_enrollment_enabled"]).to be true
    end

    it "advances the revision when a previously enrolled project re-enables through the profile" do
      StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: false)
      Configuration::Profiles::Applier.call(plan: plan_for, project:, actor: owner)

      expect(project.reload.staged_closeout_enrollment.revision).to eq(2)
    end

    it "persists the enrollment when it is the only planned change" do
      Configuration::Profiles::Applier.call(plan: plan_for, project:, actor: owner)
      StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: false)
      replan = Configuration::Profiles::Planner.call(profile:, project:, actor: owner)

      expect(replan.changes.map(&:key)).to eq([ "staged_closeout_enrollment_enabled" ])

      result = Configuration::Profiles::Applier.call(plan: replan, project:, actor: owner)

      expect(result.fetch(:applied_changes)).to contain_exactly(include(key: "staged_closeout_enrollment_enabled", applied: true))
      expect(project.reload.staged_closeout_enrollment).to be_enabled
    end

    it "is idempotent when reapplying" do
      Configuration::Profiles::Applier.call(plan: plan_for, project:, actor: owner)

      expect {
        result = Configuration::Profiles::Applier.call(plan: plan_for, project:, actor: owner)
        expect(result).to eq(applied_changes: [], skipped_levels: [])
      }.not_to change(AccountActivityEvent, :count)
      expect(project.reload.staged_closeout_enrollment.revision).to eq(1)
    end

    it "does not enable enrollment when the required project authorization is missing" do
      member = create(:user, :member, account:)
      plan = plan_for(actor: member)

      result = Configuration::Profiles::Applier.call(plan:, project:, actor: member)

      expect(result.fetch(:skipped_levels)).to include(include("level" => "project"))
      expect(project.reload.staged_closeout_enrollment).to be_nil
    end
  end

  describe "rolling back" do
    it "restores the prior enrollment value" do
      Configuration::Profiles::Applier.call(plan: plan_for, project:, actor: owner)
      event = account.account_activity_events.where(action: "configuration_profile.applied").last

      Configuration::Profiles::Rollback.call(event, actor: owner)

      enrollment = project.reload.staged_closeout_enrollment
      expect(enrollment.enabled?).to be(false)
      expect(enrollment.reviewed_by).to eq(owner)
      expect(enrollment.revision).to eq(2)
      expect(project.reload.auto_pick_enabled).to be(false)
    end

    it "re-enables enrollment when rolling back a disable" do
      StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)
      project.update_columns(owner_reviewer_login: "octocat", allowed_github_usernames: [ "octocat" ])
      plan = Configuration::Profiles::Planner.call(
        profile: Configuration::Profiles::TeamReviewed,
        project:, actor: owner, overrides: { "owner_reviewer_login" => "octocat" }
      )
      Configuration::Profiles::Applier.call(plan:, project:, actor: owner)
      expect(project.reload.staged_closeout_enrollment.enabled?).to be(false)

      event = account.account_activity_events.where(action: "configuration_profile.applied").last
      Configuration::Profiles::Rollback.call(event, actor: owner)

      expect(project.reload.staged_closeout_enrollment.enabled?).to be(true)
    end
  end

  describe "other curated profiles" do
    it "pins enrollment off explicitly instead of inheriting Fully Automatic" do
      others = Configuration::Profiles::Registry.all - [ profile ]

      expect(others).not_to be_empty
      others.each do |other|
        expect(other.targets["staged_closeout_enrollment_enabled"]).to be(false), "#{other.name} must pin enrollment off"
      end
    end

    it "disables an existing enrollment when another profile is applied" do
      StagedCloseoutAdoption::Enroll.call(project:, actor: owner, enabled: true)
      project.update_columns(allowed_github_usernames: [ "octocat" ])
      plan = Configuration::Profiles::Planner.call(
        profile: Configuration::Profiles::TeamReviewed,
        project:, actor: owner, overrides: { "owner_reviewer_login" => "octocat" }
      )

      Configuration::Profiles::Applier.call(plan:, project:, actor: owner)

      expect(project.reload.staged_closeout_enrollment.enabled?).to be(false)
    end
  end

  describe "waiting reasons when the postmerge flow cannot run" do
    it "reports no_approved_mapping for an enrolled project without mappings" do
      Configuration::Profiles::Applier.call(plan: plan_for, project:, actor: owner)

      projection = StagedCloseoutAdoption::Projection.for_project(project.reload)

      expect(projection[:enrollment]["enabled"]).to be(true)
      expect(projection[:automatic_run_reason]).to eq("no_approved_mapping")
    end

    it "reports project_not_enrolled when the enrollment stays off" do
      projection = StagedCloseoutAdoption::Projection.for_project(project)

      expect(projection[:automatic_run_reason]).to eq("project_not_enrolled")
    end
  end
end
