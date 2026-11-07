# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-003 @spec PROJECT-DELEGATION-004 @spec PROJECT-DELEGATION-006 @spec PROJECT-DELEGATION-008
RSpec.describe ProjectDelegation::ActionPlan do
  let(:project) do
    create(:project,
           delegation_posture: posture,
           delegation_enabled_action_classes: enabled_actions)
  end
  let(:issue) { create(:issue, project: project) }
  let(:posture) { ProjectDelegation::Projection::CONSERVATIVE_POSTURE }
  let(:enabled_actions) { [] }

  describe "#call" do
    context "when project is in conservative posture" do
      let(:posture) { ProjectDelegation::Projection::CONSERVATIVE_POSTURE }

      it "blocks the action" do
        plan = described_class.new(
          project: project,
          work_item: issue,
          action_class: described_class::BOUNDED_IMPLEMENTATION_CHOICE
        )

        result = plan.call

        expect(result.blocked?).to be(true)
        expect(result.status).to eq(described_class::BLOCKED)
        expect(result.reason).to eq("project_in_conservative_posture")
      end

      it "records an audit event" do
        expect {
          plan = described_class.new(
            project: project,
            work_item: issue,
            action_class: described_class::BOUNDED_IMPLEMENTATION_CHOICE
          )
          plan.call
        }.to change { ProjectDelegationAuditEvent.count }.by(1)

        event = ProjectDelegationAuditEvent.last
        expect(event.event_type).to eq(ProjectDelegationAuditEvent::DECISION_ROUTED)
        expect(event.event_data["action_class"]).to eq(described_class::BOUNDED_IMPLEMENTATION_CHOICE)
        expect(event.event_data["blocked"]).to be(true)
      end
    end

    context "when project is delegated but action class is not enabled" do
      let(:posture) { ProjectDelegation::Projection::BOUNDED_DELIVERY_POSTURE }
      let(:enabled_actions) { [] }

      it "blocks the action" do
        plan = described_class.new(
          project: project,
          work_item: issue,
          action_class: described_class::BOUNDED_IMPLEMENTATION_CHOICE
        )

        result = plan.call

        expect(result.blocked?).to be(true)
        expect(result.reason).to eq("action_class_not_enabled")
      end
    end

    context "when project is delegated and action class is enabled" do
      let(:posture) { ProjectDelegation::Projection::BOUNDED_DELIVERY_POSTURE }
      let(:enabled_actions) { [described_class::BOUNDED_IMPLEMENTATION_CHOICE] }

      it "permits the action" do
        plan = described_class.new(
          project: project,
          work_item: issue,
          action_class: described_class::BOUNDED_IMPLEMENTATION_CHOICE
        )

        result = plan.call

        expect(result.permitted?).to be(true)
        expect(result.status).to eq(described_class::PERMITTED)
      end

      it "records an admission audit event" do
        expect {
          plan = described_class.new(
            project: project,
            work_item: issue,
            action_class: described_class::BOUNDED_IMPLEMENTATION_CHOICE
          )
          plan.call
        }.to change { ProjectDelegationAuditEvent.count }.by(1)

        event = ProjectDelegationAuditEvent.last
        expect(event.event_type).to eq(ProjectDelegationAuditEvent::ACTION_ADMITTED)
      end
    end
  end
end
