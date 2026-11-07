# frozen_string_literal: true

RSpec.describe ProjectDelegationEvent do
  let(:project) { create(:project) }
  let(:actor) { create(:user, account: project.account) }

  describe "validations" do
    it { is_expected.to validate_presence_of(:action) }
    it { is_expected.to validate_inclusion_of(:action).in_array(ProjectDelegationEvent::ACTIONS) }
    it { is_expected.to validate_presence_of(:posture) }
    it { is_expected.to validate_inclusion_of(:posture).in_array(Project::DELEGATION_POSTURES) }
    it { is_expected.to validate_presence_of(:account_id) }
    it { is_expected.to validate_presence_of(:project_id) }
  end

  describe "associations" do
    it { is_expected.to belong_to(:account) }
    it { is_expected.to belong_to(:project) }
    it { is_expected.to belong_to(:actor).class_name("User").optional }
  end

  describe "scopes" do
    let!(:first_project_event) { create(:project_delegation_event, project:) }
    let!(:second_project_event) { create(:project_delegation_event, project:) }
    let!(:other_project_event) { create(:project_delegation_event) }

    describe ".for_project" do
      it "returns events for the given project" do
        expect(described_class.for_project(project)).to include(first_project_event, second_project_event)
        expect(described_class.for_project(project)).not_to include(other_project_event)
      end
    end

    describe ".by_action" do
      it "returns events with the given action" do
        result = described_class.by_action("posture_selected")
        expect(result).to include(first_project_event, second_project_event, other_project_event)
      end
    end

    describe ".chronological" do
      it "returns events in ascending order by created_at" do
        old_event = create(:project_delegation_event, project:, created_at: 2.hours.ago)
        new_event = create(:project_delegation_event, project:, created_at: 1.hour.ago)
        expect(described_class.chronological.pluck(:id)).to eq([ old_event.id, new_event.id ])
      end
    end

    describe ".recent" do
      it "returns events in descending order by created_at" do
        old_event = create(:project_delegation_event, project:, created_at: 2.hours.ago)
        new_event = create(:project_delegation_event, project:, created_at: 1.hour.ago)
        expect(described_class.recent.pluck(:id)).to eq([ new_event.id, old_event.id ])
      end
    end
  end

  describe ".record_posture_selection" do
    it "creates an event for posture selection" do
      expect {
        described_class.record_posture_selection(
          project:,
          posture: "bounded_delivery",
          actor:,
          policy_signature: "sha256:abc123",
          metadata: { "enabled_actions" => { "implementation_choice" => true } }
        )
      }.to change(described_class, :count).by(1)
    end

    it "sets all the correct attributes" do
      described_class.record_posture_selection(
        project:,
        posture: "bounded_delivery",
        actor:,
        policy_signature: "sha256:abc123",
        metadata: { "enabled_actions" => { "implementation_choice" => true } }
      )

      event = described_class.last
      expect(event.account).to eq(project.account)
      expect(event.project).to eq(project)
      expect(event.actor).to eq(actor)
      expect(event.action).to eq("posture_selected")
      expect(event.posture).to eq("bounded_delivery")
      expect(event.policy_signature).to eq("sha256:abc123")
      expect(event.metadata).to include("enabled_actions" => { "implementation_choice" => true })
    end

    it "works without an actor" do
      event = described_class.record_posture_selection(
        project:,
        posture: "conservative",
        actor: nil
      )
      expect(event.actor).to be_nil
    end
  end
end
