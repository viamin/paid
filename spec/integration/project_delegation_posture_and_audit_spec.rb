# frozen_string_literal: true

RSpec.describe "Project Delegation Posture and Audit Record", type: :integration do # rubocop:disable RSpec/DescribeClass
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:owner) { create(:user, account:) }

  before do
    create(:account_membership, account:, user: owner, role: :owner)
  end

  # @spec PROJECT-DELEGATION-001
  describe "Default conservative posture and audit trail" do
    it "defaults every project to conservative posture" do
      expect(project.delegation_posture).to eq("conservative")
    end

    it "shows the effective posture through the projection" do
      projection = ProjectDelegation::Projection.call(project)
      expect(projection.posture).to eq("conservative")
      expect(projection.conservative?).to be(true)
      expect(projection.bounded_delivery?).to be(false)
    end

    it "shows human-facing labels for the posture" do
      projection = ProjectDelegation::Projection.call(project)
      expect(projection.posture_label).to eq("Conservative (default)")
    end

    it "displays remaining required reviews" do
      projection = ProjectDelegation::Projection.call(project)
      reviews = projection.remaining_required_reviews

      expect(reviews).to include(
        phase_approval: true,
        repository_review: true,
        merge_approval: true,
        release_decision: true
      )
    end
  end

  # @spec PROJECT-DELEGATION-001
  describe "Authorized selection of delegation posture" do
    it "allows owner to select a new posture" do
      result = ProjectDelegation::SelectPosture.call(
        project:,
        actor: owner,
        posture: "bounded_delivery",
        enabled_actions: {
          "implementation_choice" => true,
          "follow_up_recording" => true
        }
      )

      expect(result.success?).to be(true)
      expect(project.reload.delegation_posture).to eq("bounded_delivery")
    end

    it "records the actor who made the selection" do
      ProjectDelegation::SelectPosture.call(
        project:,
        actor: owner,
        posture: "bounded_delivery"
      )

      expect(project.reload.delegation_posture_selected_by).to eq(owner)
    end

    it "records the timestamp of the selection" do
      before_time = Time.current
      ProjectDelegation::SelectPosture.call(
        project:,
        actor: owner,
        posture: "bounded_delivery"
      )
      after_time = Time.current

      selected_at = project.reload.delegation_posture_selected_at
      expect(selected_at).to be_between(before_time, after_time)
    end

    it "stores the enabled action classes" do
      actions = {
        "implementation_choice" => true,
        "follow_up_recording" => true,
        "technical_stop_recovery" => true,
        "evidence_gated_closeout" => true,
        "cycle_analysis_and_repair" => true
      }

      ProjectDelegation::SelectPosture.call(
        project:,
        actor: owner,
        posture: "bounded_delivery",
        enabled_actions: actions
      )

      expect(project.reload.delegation_enabled_actions).to eq(actions)
    end

    it "stores the policy signature for immutability" do
      signature = "sha256:#{SecureRandom.hex(32)}"
      ProjectDelegation::SelectPosture.call(
        project:,
        actor: owner,
        posture: "conservative",
        policy_signature: signature
      )

      expect(project.reload.delegation_policy_signature).to eq(signature)
    end
  end

  # @spec PROJECT-DELEGATION-001
  describe "Immutable audit events" do
    it "creates an audit event when posture is selected" do
      expect {
        ProjectDelegation::SelectPosture.call(
          project:,
          actor: owner,
          posture: "bounded_delivery"
        )
      }.to change(ProjectDelegationEvent, :count).by(1)
    end

    it "records the action, actor, and posture in the audit event" do
      ProjectDelegation::SelectPosture.call(
        project:,
        actor: owner,
        posture: "bounded_delivery",
        enabled_actions: { "implementation_choice" => true }
      )

      event = ProjectDelegationEvent.last
      expect(event.action).to eq("posture_selected")
      expect(event.actor).to eq(owner)
      expect(event.posture).to eq("bounded_delivery")
      expect(event.project).to eq(project)
      expect(event.account).to eq(account)
    end

    it "stores the policy signature in the audit event" do
      signature = "sha256:#{SecureRandom.hex(32)}"
      ProjectDelegation::SelectPosture.call(
        project:,
        actor: owner,
        posture: "conservative",
        policy_signature: signature
      )

      event = ProjectDelegationEvent.last
      expect(event.policy_signature).to eq(signature)
    end

    it "stores enabled actions in the audit metadata" do
      actions = { "implementation_choice" => true, "follow_up_recording" => true }
      ProjectDelegation::SelectPosture.call(
        project:,
        actor: owner,
        posture: "bounded_delivery",
        enabled_actions: actions
      )

      event = ProjectDelegationEvent.last
      expect(event.metadata["enabled_actions"]).to eq(actions)
    end

    it "preserves audit trail when changing postures" do
      # First selection
      ProjectDelegation::SelectPosture.call(
        project:,
        actor: owner,
        posture: "conservative"
      )

      # Second selection
      another_user = create(:user, account:)
      ProjectDelegation::SelectPosture.call(
        project:,
        actor: another_user,
        posture: "bounded_delivery"
      )

      events = ProjectDelegationEvent.for_project(project).chronological
      expect(events.count).to eq(2)
      expect(events[0].posture).to eq("conservative")
      expect(events[0].actor).to eq(owner)
      expect(events[1].posture).to eq("bounded_delivery")
      expect(events[1].actor).to eq(another_user)
    end
  end

  # @spec PROJECT-DELEGATION-001
  describe "Effective posture projection" do
    it "provides effective posture data to all surfaces" do
      ProjectDelegation::SelectPosture.call(
        project:,
        actor: owner,
        posture: "bounded_delivery",
        enabled_actions: { "implementation_choice" => true }
      )

      projection = ProjectDelegation::Projection.call(project)
      summary = projection.summary

      expect(summary).to include(
        posture: "bounded_delivery",
        posture_label: "Bounded Delivery",
        selected_by: owner.email,
        enabled_actions: { "implementation_choice" => true }
      )
      expect(summary[:selected_at]).to be_present
    end

    it "includes audit trail in projection" do
      ProjectDelegation::SelectPosture.call(
        project:,
        actor: owner,
        posture: "conservative"
      )

      projection = ProjectDelegation::Projection.call(project)
      expect(projection.events.count).to eq(1)
      expect(projection.last_event.posture).to eq("conservative")
    end

    it "reflects current posture and revisions" do
      # Select bounded_delivery
      ProjectDelegation::SelectPosture.call(
        project:,
        actor: owner,
        posture: "bounded_delivery",
        enabled_actions: { "implementation_choice" => true }
      )

      projection = ProjectDelegation::Projection.call(project)
      expect(projection.bounded_delivery?).to be(true)
      expect(projection.conservative?).to be(false)
    end
  end
end
