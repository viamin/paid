# frozen_string_literal: true

require "rails_helper"

# The effective project delegation posture (RDR-080): conservative is the
# default for every project, and a broader posture exists only as an explicit
# selection the required guards (automation_phases plus project_delegation)
# permit. The posture is one normalized read model for every surface; it never
# grants execution authority.
# @spec PROJECT-DELEGATION-001
RSpec.describe ProjectDelegation::Posture do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, :with_github_installation, account: account, created_by: user) }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
  end

  describe ".resolve" do
    it "defaults every project to conservative without a stored selection" do
      posture = described_class.resolve(project)

      expect(posture).to have_attributes(
        level: described_class::CONSERVATIVE,
        source: "default",
        revision: 0,
        enabled_action_classes: []
      )
      expect(posture).to be_conservative
      expect(posture).not_to be_bounded_delivery
    end

    it "lists the reviews that remain human decisions under conservative" do
      posture = described_class.resolve(project)

      expect(posture.remaining_reviews.map { |review| review[:key] })
        .to contain_exactly("approvals", "reviews", "merges", "holds", "unresolved_stops")
    end

    it "reports a stored selection as the effective posture with its revision" do
      create(:project_delegation_posture, project: project, level: "bounded_delivery", revision: 3,
        selected_by: user)

      posture = described_class.resolve(project)

      expect(posture).to have_attributes(
        level: described_class::BOUNDED_DELIVERY,
        source: "selected",
        revision: 3,
        enabled_action_classes: described_class::DELEGATED_ACTION_CLASSES
      )
      expect(posture.selected_by_id).to eq(user.id)
    end

    it "returns to conservative when expansion evidence reverses" do # @spec PROJECT-DELEGATION-007
      record = create(:project_delegation_posture, project: project, level: "bounded_delivery", selected_by: user)
      FeatureFlags.enable!(:project_delegation_expansion, project:)
      30.times do |index|
        ProjectDelegation::PilotMetrics.record(project:, event_type: "issue_completed",
          event_key: "completed-#{index}", posture: described_class.resolve_without_expansion(project),
          policy_signature: record.policy_signature, occurred_at: 15.days.ago)
      end
      ProjectDelegation::PilotMetrics.record(project:, event_type: "decision_reversed", event_key: "reversal",
        posture: described_class.resolve_without_expansion(project), policy_signature: record.policy_signature,
        occurred_at: 1.day.ago, material: true)

      posture = described_class.resolve(project)

      expect(posture).to be_conservative
      expect(posture.source).to eq("expansion_paused")
    end

    it "lists the reviews that remain human decisions under bounded_delivery" do
      create(:project_delegation_posture, project: project, level: "bounded_delivery")

      posture = described_class.resolve(project)

      expect(posture.remaining_reviews.map { |review| review[:key] })
        .to contain_exactly("material_intent", "repository_gates", "routed_exceptions")
    end

    it "falls back to conservative when the guards do not permit the capability" do
      FeatureFlags.disable!(:project_delegation, project:)
      create(:project_delegation_posture, project: project, level: "bounded_delivery")

      posture = described_class.resolve(project)

      expect(posture).to be_conservative
      expect(posture.source).to eq("guard_disabled")
    end

    it "falls back to conservative when the automation_phases rollout is off" do
      FeatureFlags.disable!(:automation_phases, project:)
      create(:project_delegation_posture, project: project, level: "bounded_delivery")

      posture = described_class.resolve(project)

      expect(posture).to be_conservative
      expect(posture.source).to eq("guard_disabled")
    end

    # @spec PROJECT-DELEGATION-001
    it "fails closed when a stored posture level is unrecognized" do
      record = build(:project_delegation_posture, project: project, level: "unknown")
      project.association(:delegation_posture).target = record

      posture = described_class.resolve(project)

      expect(posture).to be_conservative
      expect(posture.enabled_action_classes).to eq([])
      expect(posture.remaining_reviews.map { |review| review[:key] })
        .to contain_exactly("approvals", "reviews", "merges", "holds", "unresolved_stops")
    end

    it "preserves a stored conservative rollback while a guard is off" do
      selected_at = 1.hour.ago.change(usec: 0)
      record = create(:project_delegation_posture, project: project, level: "conservative", revision: 4,
        selected_by: user, enabled_action_classes: [], policy_signature: "rollback-signature", updated_at: selected_at)
      FeatureFlags.disable!(:automation_phases, project:)

      posture = described_class.resolve(project)

      expect(posture).to have_attributes(
        level: described_class::CONSERVATIVE,
        source: "selected",
        revision: 4,
        policy_signature: "rollback-signature",
        selected_by_id: user.id,
        selected_at: record.updated_at
      )
    end

    it "delegates no action classes and names the reviews under the fallback" do
      FeatureFlags.disable!(:project_delegation, project:)
      create(:project_delegation_posture, project: project, level: "bounded_delivery")

      posture = described_class.resolve(project)

      expect(posture.enabled_action_classes).to eq([])
      expect(posture.remaining_reviews.map { |review| review[:key] })
        .to contain_exactly("approvals", "reviews", "merges", "holds", "unresolved_stops")
    end
  end

  describe ".policy_signature" do
    it "digests the phase-policy state the selection relies on" do
      project.update!(
        Automation::PhaseSettings::SETTINGS_KEY => {
          Automation::PhaseSettings::PHASES_KEY => { "coding" => true },
          Automation::PhaseSettings::RELEASE_KEY => false,
          Automation::PhaseSettings::DEPLOYMENT_KEY => false
        }
      )

      expect(described_class.policy_signature(project))
        .to eq(Digest::SHA256.hexdigest(Automation::PhaseSettings.call(project).to_h.to_json))
    end

    it "changes when the phase policy changes" do
      before = described_class.policy_signature(project)

      project.update!(
        Automation::PhaseSettings::SETTINGS_KEY => {
          Automation::PhaseSettings::PHASES_KEY => { "merge" => true },
          Automation::PhaseSettings::RELEASE_KEY => false,
          Automation::PhaseSettings::DEPLOYMENT_KEY => false
        }
      )

      expect(described_class.policy_signature(project)).not_to eq(before)
    end
  end

  describe "State#to_h" do
    it "serializes the effective posture for the shared projection payload" do
      payload = described_class.resolve(project).to_h

      expect(payload).to include(
        level: "conservative",
        source: "default",
        revision: 0,
        enabled_action_classes: [],
        remaining_reviews: be_an(Array),
        policy_signature: be_a(String)
      )
      expect(payload.dig(:remaining_reviews, 0)).to include(:key, :description)
    end
  end
end
