# frozen_string_literal: true

require "rails_helper"

# Effective delegation posture resolution and guarded posture writes
# (RDR-080): every project defaults to conservative, guard-disabled projects
# fall back to conservative, and only an authorized owner or project admin
# may select, hold, or release the posture.
# @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-006
RSpec.describe ProjectDelegation::Posture do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:member) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, created_by: owner) }

  before do
    FeatureFlags.enable!(:automation_phases, project:)
    FeatureFlags.enable!(:project_delegation, project:)
  end

  describe ".resolve" do
    it "defaults a project without a posture record to conservative" do
      state = described_class.resolve(project)

      expect(state).to have_attributes(level: "conservative", source: :default, revision: nil)
      expect(state).not_to be_delegates
      expect(state.record).to be_nil
    end

    it "resolves the selected posture with its current revision" do
      posture = create(:project_delegation_posture, project: project)

      state = described_class.resolve(project)

      expect(state).to have_attributes(level: "bounded_delivery", source: :selected, revision: posture.revision)
      expect(state).to be_delegates
      expect(state.record).to eq(posture)
    end

    it "falls back to conservative while either rollout guard is disabled" do
      create(:project_delegation_posture, project: project)
      FeatureFlags.disable!(:project_delegation, project:)

      state = described_class.resolve(project)

      expect(state).to have_attributes(level: "conservative", source: :guard_disabled)
      expect(state).not_to be_delegates
      expect(state.revision).to eq(1)
    end

    it "treats a held posture as conservative-fallback delegation" do
      posture = create(:project_delegation_posture, project: project)
      posture.hold!(user: owner, reason: "paused")

      state = described_class.resolve(project)

      expect(state).to have_attributes(source: :selected, held: true, level: "bounded_delivery")
      expect(state).not_to be_delegates
    end

    it "names the reviews that stay human under each posture" do
      default_state = described_class.resolve(project)
      delegating = create(:project_delegation_posture, project: project)

      bounded_state = described_class.resolve(project)

      expect(default_state.required_human_reviews).to include("product decisions", "merge approval")
      expect(bounded_state.required_human_reviews).not_to include("bounded implementation choices")
      expect(bounded_state.required_human_reviews).to include("material intent changes", "merge approval")
      expect(delegating).to be_persisted
    end
  end

  describe ".select" do
    it "records an authorized owner's selection with actor, revision, and audit event" do
      posture = described_class.select(project: project, user: owner, level: "bounded_delivery")

      expect(posture).to have_attributes(
        level: "bounded_delivery",
        selected_by: owner,
        revision: 1,
        account_id: account.id,
        enabled_action_classes: BoundedDelegatedAction::ACTIONS
      )
      expect(account.account_activity_events.by_action("project_delegation.selected").last).to have_attributes(
        actor: owner, subject: posture
      )
    end

    it "bumps the revision when a project admin reselects" do
      admin = create(:user, :admin, account:)
      admin.add_role(:project_admin, project)
      posture = described_class.select(project: project, user: owner, level: "bounded_delivery")

      posture = described_class.select(project: project, user: admin, level: "bounded_delivery")

      expect(posture.revision).to eq(2)
      expect(posture.selected_by).to eq(admin)
    end

    it "denies selection to a plain member and records nothing" do
      expect {
        described_class.select(project: project, user: member, level: "bounded_delivery")
      }.to raise_error(ProjectDelegation::Posture::PermissionDenied, /posture/)

      expect(project.reload.project_delegation_posture).to be_nil
      expect(account.account_activity_events.by_action("project_delegation.selected")).to be_empty
    end

    it "rejects an unsupported level without writing" do
      expect {
        described_class.select(project: project, user: owner, level: "fully_autonomous")
      }.to raise_error(ProjectDelegation::Posture::InvalidLevel)

      expect(project.reload.project_delegation_posture).to be_nil
    end
  end

  describe ".hold and .release_hold" do
    it "blocks delegated work through the resolved state while retaining evidence" do
      described_class.select(project: project, user: owner, level: "bounded_delivery")

      described_class.hold(project: project, user: owner, reason: "incident review")

      state = described_class.resolve(project)
      expect(state).not_to be_delegates
      expect(state).to be_held
      expect(project.reload.project_delegation_posture.level).to eq("bounded_delivery")

      described_class.release_hold(project: project, user: owner)

      expect(described_class.resolve(project)).to be_delegates
      expect(account.account_activity_events.by_action("project_delegation.held").count).to eq(1)
      expect(account.account_activity_events.by_action("project_delegation.hold_released").count).to eq(1)
    end

    it "requires an existing posture record to hold" do
      expect {
        described_class.hold(project: project, user: owner, reason: "nothing to hold")
      }.to raise_error(ProjectDelegation::Posture::Error, /no delegation posture/)
    end

    it "denies hold to a plain member" do
      described_class.select(project: project, user: owner, level: "bounded_delivery")

      expect {
        described_class.hold(project: project, user: member, reason: "nope")
      }.to raise_error(ProjectDelegation::Posture::PermissionDenied)

      expect(project.reload.project_delegation_posture).not_to be_held
    end
  end
end
