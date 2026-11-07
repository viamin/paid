# frozen_string_literal: true

RSpec.describe ProjectDelegation::Projection do
  subject(:projection) { described_class.call(project) }

  let(:project) { create(:project, delegation_posture: "conservative") }

  describe "#posture" do
    it "returns the project's delegation posture" do
      expect(projection.posture).to eq("conservative")
    end

    it "defaults to conservative" do
      project.update!(delegation_posture: nil)
      expect(projection.posture).to eq("conservative")
    end
  end

  describe "#posture_label" do
    it "returns the human-facing label for conservative" do
      expect(projection.posture_label).to eq("Conservative (default)")
    end

    it "returns the human-facing label for bounded_delivery" do
      project.update!(delegation_posture: "bounded_delivery")
      expect(projection.posture_label).to eq("Bounded Delivery")
    end
  end

  describe "#conservative?" do
    it "returns true for conservative posture" do
      expect(projection.conservative?).to be(true)
    end

    it "returns false for bounded_delivery" do
      project.update!(delegation_posture: "bounded_delivery")
      expect(projection.conservative?).to be(false)
    end
  end

  describe "#bounded_delivery?" do
    it "returns false for conservative" do
      expect(projection.bounded_delivery?).to be(false)
    end

    it "returns true for bounded_delivery posture" do
      project.update!(delegation_posture: "bounded_delivery")
      expect(projection.bounded_delivery?).to be(true)
    end
  end

  describe "#selected_at" do
    it "returns the timestamp when the posture was selected" do
      now = Time.current
      project.update!(delegation_posture_selected_at: now)
      expect(projection.selected_at).to eq(now)
    end
  end

  describe "#selected_by" do
    it "returns the user who selected the posture" do
      user = create(:user)
      project.update!(delegation_posture_selected_by: user)
      expect(projection.selected_by).to eq(user)
    end
  end

  describe "#policy_signature" do
    it "returns the policy signature from the project" do
      signature = "sha256:abc123"
      project.update!(delegation_policy_signature: signature)
      expect(projection.policy_signature).to eq(signature)
    end
  end

  describe "#enabled_actions" do
    it "returns the enabled actions for the posture" do
      actions = { "implementation_choice" => true, "follow_up_recording" => true }
      project.update!(delegation_enabled_actions: actions)
      expect(projection.enabled_actions).to eq(actions)
    end

    it "defaults to empty hash" do
      project.update!(delegation_enabled_actions: nil)
      expect(projection.enabled_actions).to eq({})
    end
  end

  describe "#events" do
    it "returns delegation events in chronological order" do
      event1 = create(:project_delegation_event, project:, created_at: 1.hour.ago)
      event2 = create(:project_delegation_event, project:)
      expect(projection.events).to eq([ event1, event2 ])
    end
  end

  describe "#last_event" do
    it "returns the most recent delegation event" do
      create(:project_delegation_event, project:, created_at: 1.hour.ago)
      recent_event = create(:project_delegation_event, project:)
      expect(projection.last_event).to eq(recent_event)
    end
  end

  describe "#summary" do
    it "returns a summary hash with key projection data" do
      user = create(:user)
      now = Time.current
      project.update!(
        delegation_posture: "bounded_delivery",
        delegation_posture_selected_by: user,
        delegation_posture_selected_at: now,
        delegation_enabled_actions: { "implementation_choice" => true }
      )

      summary = projection.summary
      expect(summary).to include(
        posture: "bounded_delivery",
        posture_label: "Bounded Delivery",
        selected_at: now,
        selected_by: user.email,
        enabled_actions: { "implementation_choice" => true }
      )
    end
  end
end
