# frozen_string_literal: true

require "rails_helper"

# @spec AUTOMATION-PHASES-003 @spec AUTOMATION-PHASES-007 @spec AUTOMATION-PHASES-017
# @spec BOUNDED-PHASE-AUTHORIZATION-003
RSpec.describe Automation::EffectivePolicy do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }

  before { FeatureFlags.enable!(:automation_phases, project:) }

  it "includes the fail-closed effective posture in the canonical decision" do # @spec PROJECT-DELEGATION-004
    decision = described_class.call(project:, phase: "coding", work_item: issue,
      delegated_action: "review", rollout_enabled: true)

    expect(decision).to be_blocked
    expect(decision.reason).to eq(:posture_restricted)
    expect(decision.to_h[:phase_policy_signature]).to be_a(String)
    expect(decision.to_h[:posture]).to include(
      level: "conservative", revision: 0, policy_signature: kind_of(String)
    )
  end

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

  describe "rollout guard" do
    it "keeps the legacy policy while the flag is off" do
      FeatureFlags.disable!(:automation_phases, project:)
      configure({ "merge" => false })

      decision = decide(phase: "merge")

      expect(decision).to be_permitted
      expect(decision.source).to eq(:legacy_policy)
    end

    it "does not evaluate phase or posture state while the flag is off" do
      legacy_project = Object.new

      decision = described_class.call(project: legacy_project, phase: "merge", rollout_enabled: false)

      expect(decision).to be_permitted
      expect(decision.to_h).to include(
        source: :legacy_policy,
        phase_policy_signature: nil,
        posture: nil
      )
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

  describe "bounded phase stops" do
    let(:pull_request) { create(:issue, :pull_request, project:, github_number: 21, parent_issue_id: issue.id) }

    def authorize_bounded(action:, work_item: issue)
      create(:bounded_delegated_action, account: account, project: project, issue: work_item,
        action: action,
        evidence: Automation::DelegatedActionAdmission.admission_evidence(
          work_item: work_item, action: action, acceptance_refs: [ "AC-1" ],
          stop_before_phase: Automation::DelegatedActionAdmission::STOP_BEFORE_PHASES.fetch(action)
        ))
    end

    before { configure({ "coding" => true, "merge" => true, "release_deployment" => true }) }

    it "returns a visible stop at the selected boundary even when defaults would continue" do # @spec BOUNDED-PHASE-AUTHORIZATION-003
      authorize_bounded(action: "review")

      decision = decide(phase: "merge")

      expect(decision).to be_blocked
      expect(decision.reason).to eq(:bounded_phase_stop)
    end

    it "stops the boundary even when an ordinary continuation grant covers the phase" do # @spec BOUNDED-PHASE-AUTHORIZATION-003
      authorize_bounded(action: "review")
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

      decision = decide(phase: "merge")

      expect(decision).to be_blocked
      expect(decision.reason).to eq(:bounded_phase_stop)
    end

    it "keeps ordinary continuation grants non-stopping without a bounded stop" do # @spec BOUNDED-PHASE-AUTHORIZATION-003
      configure({ "coding" => false, "merge" => false })
      create(:work_item_continuation_grant, project:, issue:, start_phase: "coding", endpoint: "merge")

      decision = decide(phase: "merge")

      expect(decision).to be_permitted
      expect(decision.source).to eq(:continuation_grant)
    end

    it "preserves fully automatic merging where no bounded authorization governs the lineage" do # @spec BOUNDED-PHASE-AUTHORIZATION-003
      decision = decide(phase: "merge", work_item: pull_request)

      expect(decision).to be_permitted
      expect(decision.source).to eq(:project_defaults)
    end

    it "applies the stop through the same-work lineage" do # @spec BOUNDED-PHASE-AUTHORIZATION-003
      pull_request # establish the linked PR before the lineage is pinned
      authorize_bounded(action: "review")

      decision = decide(phase: "merge", work_item: pull_request)

      expect(decision).to be_blocked
      expect(decision.reason).to eq(:bounded_phase_stop)
    end

    it "does not extend the stop to another lineage" do # @spec BOUNDED-PHASE-AUTHORIZATION-002 BOUNDED-PHASE-AUTHORIZATION-003
      authorize_bounded(action: "review")
      other_issue = create(:issue, project:)
      other_project = create(:project, account: account)
      other_project_issue = create(:issue, project: other_project)

      expect(decide(phase: "merge", work_item: other_issue)).to be_permitted
      expect(decide(phase: "merge", work_item: other_project_issue)).to be_permitted
    end

    it "keeps the stop after revocation, expiry, and completion" do # @spec BOUNDED-PHASE-AUTHORIZATION-003
      revoked = authorize_bounded(action: "review")
      revoked.update!(status: "revoked")
      expect(decide(phase: "merge")).to be_blocked

      expired = authorize_bounded(action: "review")
      expired.update!(expires_at: 1.hour.ago)
      expect(decide(phase: "merge")).to be_blocked

      completed = authorize_bounded(action: "review")
      completed.update!(status: "completed")
      expect(decide(phase: "merge").reason).to eq(:bounded_phase_stop)
    end

    it "lets a newer explicit authorization supersede the stop for its phase" do # @spec BOUNDED-PHASE-AUTHORIZATION-003
      pull_request # establish the linked PR before the lineage is pinned
      authorize_bounded(action: "review")
      authorize_bounded(action: "merge", work_item: pull_request)

      expect(decide(phase: "merge", work_item: pull_request)).to be_permitted
      expect(decide(phase: "release_deployment", work_item: pull_request)).to be_blocked
      expect(decide(phase: "release_deployment", work_item: pull_request).reason).to eq(:bounded_phase_stop)
    end

    it "does not stop an operator's explicit manual action" do # @spec BOUNDED-PHASE-AUTHORIZATION-003
      authorize_bounded(action: "review")

      decision = decide(phase: "merge", trigger: :manual)

      expect(decision).to be_permitted
      expect(decision.source).to eq(:manual_action)
    end

    it "keeps the stop off while the rollout guard is disabled" do # @spec BOUNDED-PHASE-AUTHORIZATION-003 AUTOMATION-PHASES-014
      FeatureFlags.disable!(:automation_phases, project:)
      authorize_bounded(action: "review")

      decision = decide(phase: "merge")

      expect(decision).to be_permitted
      expect(decision.source).to eq(:legacy_policy)
    end
  end
end
