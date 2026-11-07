# frozen_string_literal: true

RSpec.describe ProjectDelegation::SelectPosture do
  let(:project) { create(:project) }
  let(:actor) { create(:user, account: project.account) }

  describe "call" do
    context "when selecting conservative posture" do
      it "updates the project with the new posture" do
        result = described_class.call(
          project:,
          actor:,
          posture: "conservative"
        )

        expect(result.success?).to be(true)
        expect(project.reload.delegation_posture).to eq("conservative")
      end

      it "records the actor and timestamp" do
        now = Time.current
        allow(Time).to receive(:current).and_return(now)

        described_class.call(
          project:,
          actor:,
          posture: "conservative"
        )

        expect(project.reload.delegation_posture_selected_by).to eq(actor)
        expect(project.reload.delegation_posture_selected_at).to eq(now)
      end

      it "stores the policy signature" do
        signature = "sha256:abc123"
        described_class.call(
          project:,
          actor:,
          posture: "conservative",
          policy_signature: signature
        )

        expect(project.reload.delegation_policy_signature).to eq(signature)
      end

      it "stores enabled actions" do
        actions = { "implementation_choice" => true }
        described_class.call(
          project:,
          actor:,
          posture: "conservative",
          enabled_actions: actions
        )

        expect(project.reload.delegation_enabled_actions).to eq(actions)
      end
    end

    context "when selecting bounded_delivery posture" do
      it "updates the project with the new posture" do
        result = described_class.call(
          project:,
          actor:,
          posture: "bounded_delivery",
          enabled_actions: {
            "implementation_choice" => true,
            "follow_up_recording" => true
          }
        )

        expect(result.success?).to be(true)
        expect(project.reload.delegation_posture).to eq("bounded_delivery")
      end

      it "stores all enabled actions" do
        actions = {
          "implementation_choice" => true,
          "follow_up_recording" => true,
          "technical_stop_recovery" => true,
          "evidence_gated_closeout" => true,
          "cycle_analysis_and_repair" => true
        }
        described_class.call(
          project:,
          actor:,
          posture: "bounded_delivery",
          enabled_actions: actions
        )

        expect(project.reload.delegation_enabled_actions).to eq(actions)
      end
    end

    context "when recording audit events" do
      it "creates a project delegation event" do
        expect {
          described_class.call(
            project:,
            actor:,
            posture: "conservative"
          )
        }.to change(ProjectDelegationEvent, :count).by(1)
      end

      it "records the posture in the audit event" do
        described_class.call(
          project:,
          actor:,
          posture: "conservative"
        )

        event = ProjectDelegationEvent.last
        expect(event.posture).to eq("conservative")
        expect(event.action).to eq("posture_selected")
        expect(event.project).to eq(project)
        expect(event.actor).to eq(actor)
      end

      it "includes enabled_actions in the audit metadata" do
        actions = { "implementation_choice" => true }
        described_class.call(
          project:,
          actor:,
          posture: "bounded_delivery",
          enabled_actions: actions
        )

        event = ProjectDelegationEvent.last
        expect(event.metadata["enabled_actions"]).to eq(actions)
      end

      it "records the policy signature in the audit event" do
        signature = "sha256:def456"
        described_class.call(
          project:,
          actor:,
          posture: "bounded_delivery",
          policy_signature: signature
        )

        event = ProjectDelegationEvent.last
        expect(event.policy_signature).to eq(signature)
      end
    end

    context "when validating input" do
      it "raises ArgumentError for invalid posture" do
        expect {
          described_class.call(
            project:,
            actor:,
            posture: "invalid_posture"
          )
        }.to raise_error(ArgumentError, /posture must be one of/)
      end

      it "raises ArgumentError when actor is not a User" do
        expect {
          described_class.call(
            project:,
            actor: "not a user",
            posture: "conservative"
          )
        }.to raise_error(ArgumentError, /actor must be a User/)
      end

      it "raises ArgumentError when project is not a Project" do
        expect {
          described_class.call(
            project: "not a project",
            actor:,
            posture: "conservative"
          )
        }.to raise_error(ArgumentError, /project must be a Project/)
      end
    end

    context "with transaction safety" do
      it "uses a lock to prevent concurrent updates" do
        expect(project).to receive(:with_lock).and_yield
        described_class.call(
          project:,
          actor:,
          posture: "conservative"
        )
      end
    end
  end
end
