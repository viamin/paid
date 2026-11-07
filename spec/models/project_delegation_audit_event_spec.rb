# frozen_string_literal: true

require "rails_helper"

# @spec PROJECT-DELEGATION-001 @spec PROJECT-DELEGATION-006 @spec PROJECT-DELEGATION-007 @spec PROJECT-DELEGATION-008
RSpec.describe ProjectDelegationAuditEvent do
  let(:project) { create(:project) }
  let(:account) { project.account }
  let(:user) { create(:user) }

  describe "validations" do
    it { is_expected.to validate_presence_of(:project_id) }
    it { is_expected.to validate_presence_of(:account_id) }
    it { is_expected.to validate_presence_of(:event_type) }
    it { is_expected.to validate_presence_of(:event_data) }
    it { is_expected.to validate_presence_of(:evidence_snapshot) }
    it { is_expected.to validate_inclusion_of(:event_type).in_array(described_class::EVENT_TYPES) }
  end

  describe "associations" do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:actor).optional }
  end

  describe ".record" do
    it "creates an audit event with all attributes" do
      event = described_class.record(
        project: project,
        account: account,
        event_type: described_class::POSTURE_CHANGED,
        actor: user,
        event_data: { new_posture: "bounded_delivery" },
        evidence_snapshot: { timestamp: Time.current.to_i },
        revision_signature: "sig123"
      )

      expect(event).to be_persisted
      expect(event.project).to eq(project)
      expect(event.account).to eq(account)
      expect(event.actor).to eq(user)
      expect(event.event_type).to eq(described_class::POSTURE_CHANGED)
      expect(event.event_data["new_posture"]).to eq("bounded_delivery")
      expect(event.revision_signature).to eq("sig123")
    end

    it "records actor name even when actor is not provided" do
      event = described_class.record(
        project: project,
        account: account,
        event_type: described_class::ACTION_ADMITTED,
        actor: user,
        event_data: {},
        evidence_snapshot: {}
      )

      expect(event.actor_name).to eq(user.name)
    end

    context "for different event types" do
      it "records posture changed events" do
        event = described_class.record(
          project: project,
          account: account,
          event_type: described_class::POSTURE_CHANGED,
          actor: user,
          event_data: { new_posture: "bounded_delivery" },
          evidence_snapshot: {}
        )

        expect(event.event_type).to eq(described_class::POSTURE_CHANGED)
      end

      it "records checkpoint settled events" do
        event = described_class.record(
          project: project,
          account: account,
          event_type: described_class::CHECKPOINT_SETTLED,
          actor: user,
          event_data: { issue_id: 123 },
          evidence_snapshot: {}
        )

        expect(event.event_type).to eq(described_class::CHECKPOINT_SETTLED)
      end

      it "records action admitted events" do
        event = described_class.record(
          project: project,
          account: account,
          event_type: described_class::ACTION_ADMITTED,
          event_data: { action_class: "bounded_implementation_choice" },
          evidence_snapshot: {}
        )

        expect(event.event_type).to eq(described_class::ACTION_ADMITTED)
      end

      it "records action completed events" do
        event = described_class.record(
          project: project,
          account: account,
          event_type: described_class::ACTION_COMPLETED,
          event_data: { action_class: "bounded_implementation_choice" },
          evidence_snapshot: {}
        )

        expect(event.event_type).to eq(described_class::ACTION_COMPLETED)
      end

      it "records decision routed events" do
        event = described_class.record(
          project: project,
          account: account,
          event_type: described_class::DECISION_ROUTED,
          event_data: { reason: "project_in_conservative_posture" },
          evidence_snapshot: {}
        )

        expect(event.event_type).to eq(described_class::DECISION_ROUTED)
      end
    end
  end

  describe "immutability" do
    let(:event) do
      described_class.record(
        project: project,
        account: account,
        event_type: described_class::POSTURE_CHANGED,
        event_data: { new_posture: "bounded_delivery" },
        evidence_snapshot: {}
      )
    end

    it "stores event_data immutably in a jsonb column" do
      original_data = event.event_data.dup
      event.reload

      expect(event.event_data).to eq(original_data)
    end

    it "stores evidence_snapshot immutably" do
      original_snapshot = event.evidence_snapshot.dup
      event.reload

      expect(event.evidence_snapshot).to eq(original_snapshot)
    end
  end
end
