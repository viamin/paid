# frozen_string_literal: true

require "rails_helper"

RSpec.describe Configuration::Profiles::Planner do
  let(:project) { create(:project) }
  let(:profile) { Configuration::Profiles::SoloAutomated }

  def current(key)
    Configuration::Profiles::Settings.read(project, key)
  end

  describe "#call" do
    it "produces a change for every target that differs from the current state" do
      plan = described_class.call(profile:, project:)

      changed_keys = plan.changes.map(&:key)
      expected_changes = profile.targets.reject { |key, value| current(key) == value }.keys
      expect(changed_keys).to match_array(expected_changes)
    end

    it "captures the from and to values on each change" do
      plan = described_class.call(profile:, project:)

      change = plan.changes.find { |candidate| candidate.key == "auto_pick_enabled" }
      expect(change).to have_attributes(key: "auto_pick_enabled", from: false, to: true)
    end

    it "records the resolved profile name" do
      plan = described_class.call(profile:, project:)
      expect(plan.profile_name).to eq("solo_automated")
    end

    context "when the project already matches every target" do
      it "detects the no-op and produces no changes" do
        Configuration::Profiles::Applier.call(
          plan: described_class.call(profile:, project:), project:, actor: create(:user, :owner, account: project.account)
        )

        second_plan = described_class.call(profile:, project:)
        expect(second_plan).to be_no_op
        expect(second_plan.changes).to be_empty
      end
    end

    context "when a declared override is supplied" do
      it "merges the override into the effective targets" do
        plan = described_class.call(profile:, project:, overrides: { "quality_gate_enabled" => true })

        change = plan.changes.find { |candidate| candidate.key == "quality_gate_enabled" }
        expect(change.to).to be true
        expect(plan.applied_overrides).to include("quality_gate_enabled" => true)
      end

      it "treats a no-op override as a no-op for that key" do
        plan = described_class.call(profile:, project:, overrides: { "quality_gate_enabled" => false })
        expect(plan.changes.map(&:key)).not_to include("quality_gate_enabled")
      end

      it "coerces boolean overrides before comparing current and target values" do
        project.update!(quality_gate_settings: { "enabled" => false })

        plan = described_class.call(profile:, project:, overrides: { "quality_gate_enabled" => "false" })

        expect(plan.applied_overrides).to include("quality_gate_enabled" => false)
        expect(plan.changes.map(&:key)).not_to include("quality_gate_enabled")
      end

      it "rejects invalid boolean overrides" do
        expect {
          described_class.call(profile:, project:, overrides: { "quality_gate_enabled" => "no" })
        }.to raise_error(ArgumentError, /Invalid boolean override/)
      end
    end

    context "when an undeclared override key is supplied" do
      it "rejects the override" do
        expect {
          described_class.call(profile:, project:, overrides: { "merge_method" => "rebase" })
        }.to raise_error(Configuration::Profiles::UnknownOverrideError, /does not declare override keys/)
      end
    end

    it "stringifies symbol override keys before validating" do
      expect {
        described_class.call(profile:, project:, overrides: { bogus: 1 })
      }.to raise_error(Configuration::Profiles::UnknownOverrideError)
    end
  end

  describe "prerequisites" do
    it "surfaces unmet prerequisites on the plan" do
      allow(Github::ReviewBotInstallationToken).to receive(:configured?).and_return(false)
      plan = described_class.call(profile: Configuration::Profiles::TeamReviewed, project:)

      expect(plan).to be_blocked
      expect(plan.unmet_prerequisites).to include(a_string_matching(/owner_reviewer_login/i))
    end
  end
end
