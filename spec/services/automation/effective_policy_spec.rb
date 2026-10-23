# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-003 @spec AUTOMATION-PHASES-007 @spec AUTOMATION-PHASES-017
RSpec.describe Automation::EffectivePolicy do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }

  def configure(phases)
    project.update!(
      Automation::PhaseSettings::SETTINGS_KEY => {
        Automation::PhaseSettings::PHASES_KEY => phases,
        Automation::PhaseSettings::RELEASE_KEY => false,
        Automation::PhaseSettings::DEPLOYMENT_KEY => false
      }
    )
  end

  def decide(phase:, work_item: issue, trigger: :automatic)
    described_class.call(project:, phase:, work_item:, trigger:)
  end

  before { FeatureFlags.enable!(:automation_phases, project:) }

  describe "rollout guard" do
    it "keeps the legacy policy while the flag is off" do
      FeatureFlags.disable!(:automation_phases, project:)
      configure({ "merge" => false })

      decision = decide(phase: "merge")

      expect(decision).to be_permitted
      expect(decision.source).to eq(:legacy_policy)
    end
  end

  describe "project defaults" do
    it "permits automatic work when the phase is enabled" do
      configure({ "coding" => true })

      expect(decide(phase: "coding").source).to eq(:project_defaults)
    end

    it "blocks automatic work and records why when the phase is disabled" do
      configure({ "coding" => false })

      decision = decide(phase: "coding")

      expect(decision).to be_blocked
      expect(decision.reason).to eq(:phase_disabled)
      expect(decision.source).to be_nil
    end
  end

  describe "explicit manual actions" do
    it "permits a manual start in a disabled phase" do
      configure({ "coding" => false })

      decision = decide(phase: "coding", trigger: :manual)

      expect(decision).to be_permitted
      expect(decision.source).to eq(:manual_action)
    end
  end

  describe "continuation grants" do
    before { configure({ "coding" => false, "merge" => false }) }

    it "authorizes the covered phase even when the project phase and auto-pick are off" do
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

      decision = decide(phase: "coding")

      expect(decision).to be_permitted
      expect(decision.source).to eq(:continuation_grant)
      expect(decision.to_h[:grant_id]).to be_present
    end

    it "authorizes a later covered phase without authorizing an earlier one" do
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

      expect(decide(phase: "merge")).to be_permitted
      expect(decide(phase: "issue_preparation")).to be_blocked
    end

    it "stops authorizing once the grant is revoked" do
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      grant.revoke!(user:)

      expect(decide(phase: "coding")).to be_blocked
    end

    it "stops authorizing once the grant reached its endpoint" do
      grant = create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")
      grant.complete!

      expect(decide(phase: "coding")).to be_blocked
    end

    it "does not authorize release or deployment through a merge endpoint" do
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

      expect(decide(phase: "release_deployment")).to be_blocked
    end

    it "does not authorize an unrelated work item" do
      other_issue = create(:issue, project:)
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

      expect(described_class.call(project:, phase: "coding", work_item: other_issue, trigger: :automatic))
        .to be_blocked
    end
  end

  describe "operations" do
    it "keeps an operations-originated handoff from authorizing coding" do
      configure({ "coding" => false, "merge" => false })
      incident_issue = create(:issue, project:, labels: [ project.feature_activation_label_for("auto_pick") ])

      expect(decide(phase: "coding", work_item: incident_issue)).to be_blocked
    end
  end
end
