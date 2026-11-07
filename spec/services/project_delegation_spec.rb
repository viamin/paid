# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-006
RSpec.describe ProjectDelegation do
  describe ".authorize_posture" do
    let(:project) { create(:project) }
    let(:user) { create(:user) }

    context "with valid posture" do
      it "updates project with new posture" do
        described_class.authorize_posture(
          project: project,
          posture: described_class::Projection::CONSERVATIVE_POSTURE,
          actor: user
        )

        expect(project.reload.delegation_posture).to eq(described_class::Projection::CONSERVATIVE_POSTURE)
      end

      it "records the authorizing actor" do
        described_class.authorize_posture(
          project: project,
          posture: described_class::Projection::CONSERVATIVE_POSTURE,
          actor: user
        )

        expect(project.reload.delegation_authorized_by).to eq(user)
      end

      it "records the authorization timestamp" do
        before_time = Time.current
        described_class.authorize_posture(
          project: project,
          posture: described_class::Projection::CONSERVATIVE_POSTURE,
          actor: user
        )
        after_time = Time.current

        authorization_time = project.reload.delegation_authorized_at
        expect(authorization_time).to be_between(before_time, after_time)
      end

      it "creates an audit event" do
        expect {
          described_class.authorize_posture(
            project: project,
            posture: described_class::Projection::BOUNDED_DELIVERY_POSTURE,
            actor: user,
            enabled_action_classes: [ProjectDelegation::ActionPlan::BOUNDED_IMPLEMENTATION_CHOICE]
          )
        }.to change { ProjectDelegationAuditEvent.count }.by(1)

        event = ProjectDelegationAuditEvent.last
        expect(event.event_type).to eq(ProjectDelegationAuditEvent::POSTURE_CHANGED)
        expect(event.actor).to eq(user)
        expect(event.project).to eq(project)
        expect(event.event_data["new_posture"]).to eq(described_class::Projection::BOUNDED_DELIVERY_POSTURE)
      end

      it "enables specified action classes when delegating" do
        actions = [
          ProjectDelegation::ActionPlan::BOUNDED_IMPLEMENTATION_CHOICE,
          ProjectDelegation::ActionPlan::TECHNICAL_STOP_RECOVERY
        ]

        described_class.authorize_posture(
          project: project,
          posture: described_class::Projection::BOUNDED_DELIVERY_POSTURE,
          actor: user,
          enabled_action_classes: actions
        )

        expect(project.reload.delegation_enabled_action_classes).to eq(actions)
      end
    end

    context "with invalid posture" do
      it "raises an error" do
        expect {
          described_class.authorize_posture(
            project: project,
            posture: "invalid_posture",
            actor: user
          )
        }.to raise_error(ArgumentError)
      end
    end
  end

  describe ".projection_for" do
    let(:project) { create(:project, delegation_posture: described_class::Projection::CONSERVATIVE_POSTURE) }

    it "returns a projection" do
      projection = described_class.projection_for(project: project)
      expect(projection).to be_a(described_class::Projection)
    end

    it "reflects the project's current posture" do
      projection = described_class.projection_for(project: project)
      expect(projection.effective_posture).to eq(described_class::Projection::CONSERVATIVE_POSTURE)
    end
  end

  describe ".intent_checkpoint_for" do
    let(:issue) { create(:issue) }

    it "returns an intent checkpoint plan" do
      checkpoint = described_class.intent_checkpoint_for(issue: issue)
      expect(checkpoint).to be_a(described_class::IntentCheckpoint::Plan)
    end
  end

  describe ".evaluate_action" do
    let(:project) { create(:project, delegation_posture: described_class::Projection::BOUNDED_DELIVERY_POSTURE) }
    let(:issue) { create(:issue, project: project) }

    context "when action is not delegated" do
      it "returns a blocked result" do
        result = described_class.evaluate_action(
          project: project,
          work_item: issue,
          action_class: described_class::ActionPlan::BOUNDED_IMPLEMENTATION_CHOICE
        )

        expect(result.blocked?).to be(true)
      end
    end
  end
end
