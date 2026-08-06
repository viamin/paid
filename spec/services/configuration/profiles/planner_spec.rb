# frozen_string_literal: true

require "rails_helper"

# @spec CONFIG-PROFILES-003
RSpec.describe Configuration::Profiles::Planner do
  let(:project) { create(:project) }
  let(:profile) { Configuration::Profiles::SoloAutomated }
  let(:actor) { create(:user, :owner, account: project.account) }

  def current(key)
    Configuration::Profiles::Settings.read(Configuration::Profiles::Context.build(project:, actor:), key)
  end

  describe "#call" do
    before do
      allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(true)
    end

    it "produces a change for every target that differs from the current state" do
      plan = described_class.call(profile:, project:, actor:)

      changed_keys = plan.changes.map(&:key)
      expected_changes = profile.targets.reject { |key, value| current(key) == value }.keys
      expect(changed_keys).to match_array(expected_changes)
    end

    it "captures the from and to values on each change" do
      plan = described_class.call(profile:, project:, actor:)

      change = plan.changes.find { |candidate| candidate.key == "auto_pick_enabled" }
      expect(change).to have_attributes(key: "auto_pick_enabled", from: false, to: true, level: :project)
    end

    it "records the resolved profile name" do
      plan = described_class.call(profile:, project:, actor:)
      expect(plan.profile_name).to eq("solo_automated")
    end

    it "includes user and tenant scoped changes in mixed-scope profiles" do
      actor.settings.update!(run_concurrency_mode: "auto")
      plan = described_class.call(profile: Configuration::Profiles::ObserveOnly, project:, actor:)

      expect(plan.changes).to include(have_attributes(key: "run_concurrency_mode", level: :user, from: "auto", to: "manual"))
      expect(plan.changes.map(&:level)).to include(:project, :tenant, :user)
    end

    context "when the project already matches every target" do
      it "detects the no-op and produces no changes" do
        Configuration::Profiles::Applier.call(
          plan: described_class.call(profile:, project:, actor:), project:, actor:
        )

        second_plan = described_class.call(profile:, project:, actor:)
        expect(second_plan).to be_no_op
        expect(second_plan.changes).to be_empty
      end
    end

    context "when a declared override is supplied" do
      it "merges the override into the effective targets" do
        plan = described_class.call(profile:, project:, overrides: { "quality_gate_enabled" => true }, actor:)

        change = plan.changes.find { |candidate| candidate.key == "quality_gate_enabled" }
        expect(change.to).to be true
        expect(plan.applied_overrides).to include("quality_gate_enabled" => true)
      end

      it "treats a no-op override as a no-op for that key" do
        plan = described_class.call(profile:, project:, overrides: { "quality_gate_enabled" => false }, actor:)
        expect(plan.changes.map(&:key)).not_to include("quality_gate_enabled")
      end

      it "coerces boolean overrides before comparing current and target values" do
        project.update!(quality_gate_settings: { "enabled" => false })

        plan = described_class.call(profile:, project:, overrides: { "quality_gate_enabled" => "false" }, actor:)

        expect(plan.applied_overrides).to include("quality_gate_enabled" => false)
        expect(plan.changes.map(&:key)).not_to include("quality_gate_enabled")
      end

      it "rejects invalid boolean overrides" do
        expect {
          described_class.call(profile:, project:, overrides: { "quality_gate_enabled" => "no" }, actor:)
        }.to raise_error(ArgumentError, /Invalid boolean override/)
      end
    end

    context "when a GitHub login override is supplied" do
      let(:profile) { Configuration::Profiles::TeamReviewed }

      it "normalizes the login before returning the plan" do
        plan = described_class.call(profile:, project:, overrides: { "owner_reviewer_login" => " octocat " })

        expect(plan.applied_overrides).to include("owner_reviewer_login" => "octocat")
      end

      it "rejects non-string GitHub login overrides" do
        expect {
          described_class.call(profile:, project:, overrides: { "owner_reviewer_login" => { "login" => "octocat" } }, actor:)
        }.to raise_error(ArgumentError, /Invalid GitHub login override/)
      end
    end

    context "when an undeclared override key is supplied" do
      it "rejects the override" do
        expect {
          described_class.call(profile:, project:, overrides: { "merge_method" => "rebase" }, actor:)
        }.to raise_error(Configuration::Profiles::UnknownOverrideError, /does not declare override keys/)
      end
    end

    it "stringifies symbol override keys before validating" do
      expect {
        described_class.call(profile:, project:, overrides: { bogus: 1 }, actor:)
      }.to raise_error(Configuration::Profiles::UnknownOverrideError)
    end

    context "when overrides is not a Hash" do
      it "raises ArgumentError for a string" do
        expect {
          described_class.call(profile:, project:, overrides: "quality_gate_enabled=true", actor:)
        }.to raise_error(ArgumentError, /overrides must be a Hash/)
      end

      it "raises ArgumentError for an array" do
        expect {
          described_class.call(profile:, project:, overrides: [ "quality_gate_enabled" ], actor:)
        }.to raise_error(ArgumentError, /overrides must be a Hash/)
      end

      it "raises ArgumentError for nil" do
        expect {
          described_class.call(profile:, project:, overrides: nil, actor:)
        }.to raise_error(ArgumentError, /overrides must be a Hash/)
      end
    end

    it "reports skipped levels for unauthorized mixed-scope targets" do
      member = create(:user, :member, account: project.account)
      member.settings.update!(run_concurrency_mode: "auto")

      plan = described_class.call(profile: Configuration::Profiles::ObserveOnly, project:, actor: member)

      expect(plan.skipped_levels).to contain_exactly(
        include("level" => "project", "reason" => "Not authorized to update project settings"),
        include("level" => "tenant", "reason" => "Not authorized to update tenant settings")
      )
    end

    it "does not create missing settings rows while planning a mixed-scope profile" do
      expect(actor.user_setting).to be_nil
      expect(project.account.tenant_setting).to be_nil

      expect {
        described_class.call(profile: Configuration::Profiles::ObserveOnly, project:, actor:)
      }.not_to change { [ UserSetting.count, TenantSetting.count ] }

      expect(actor.reload.user_setting).to be_nil
      expect(project.account.reload.tenant_setting).to be_nil
    end
  end

  describe "prerequisites" do
    it "surfaces unmet prerequisites on the plan" do
      plan = described_class.call(profile: Configuration::Profiles::TeamReviewed, project:)

      expect(plan).to be_blocked
      expect(plan.unmet_prerequisites).to include(a_string_matching(/owner_reviewer_login/i))
    end

    it "blocks profiles that enable paid-agent review without the review bot app" do
      allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(false)

      plan = described_class.call(profile: Configuration::Profiles::QualityStrict, project:)

      expect(plan).to be_blocked
      expect(plan.unmet_prerequisites).to include(a_string_matching(/review bot/i))
    end
  end
end
