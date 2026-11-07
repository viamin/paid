# frozen_string_literal: true

require "rails_helper"

RSpec.describe Automation::DelegationRollback do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: user) }
  let(:issue) { create(:issue, project: project) }
  let(:bounded_action) do
    create(:bounded_delegated_action, project: project, issue: issue, action: "review",
      expires_at: 1.day.from_now)
  end
  let(:snapshot_data) do
    {
      account_id: account.id,
      project_id: project.id,
      issue_id: issue.id,
      intent_revision: "sha256:abc123",
      posture_signature: "posture:sig123"
    }
  end

  describe ".on_expiry" do
    it "rolls back admission snapshots when authorization expires" do # @spec PROJECT-DELEGATION-006
      snapshot = AdmissionSnapshot.record(
        bounded_action: bounded_action,
        boundary: :queue,
        snapshot: snapshot_data
      )

      described_class.on_expiry(bounded_action: bounded_action)

      expect(snapshot.reload.status).to eq("rolled_back")
      expect(snapshot.rollback_reason).to include("expired")
    end

    it "routes recovery decisions to the Inbox when rolling back" do
      snapshot = AdmissionSnapshot.record(
        bounded_action: bounded_action,
        boundary: :queue,
        snapshot: snapshot_data
      )

      expect(Automation::FocusedDecision).to receive(:call).with(
        hash_including(
          account: snapshot.account,
          subject: snapshot.issue,
          source: "delegation_rollback"
        )
      )

      described_class.on_expiry(bounded_action: bounded_action)
    end
  end

  describe ".on_posture_change" do
    context "when posture narrows" do
      it "rolls back active admission snapshots for the project" do # @spec PROJECT-DELEGATION-006
        snapshot = AdmissionSnapshot.record(
          bounded_action: bounded_action,
          boundary: :queue,
          snapshot: snapshot_data
        )

        described_class.on_posture_change(project: project, old_posture: "bounded_delivery",
          new_posture: "conservative")

        expect(snapshot.reload.status).to eq("rolled_back")
        expect(snapshot.rollback_reason).to include("narrowed")
      end

      it "does not roll back when posture broadens" do
        snapshot = AdmissionSnapshot.record(
          bounded_action: bounded_action,
          boundary: :queue,
          snapshot: snapshot_data
        )

        described_class.on_posture_change(project: project, old_posture: "conservative",
          new_posture: "bounded_delivery")

        expect(snapshot.reload.status).to eq("active")
      end

      it "does not roll back when posture remains unchanged" do
        snapshot = AdmissionSnapshot.record(
          bounded_action: bounded_action,
          boundary: :queue,
          snapshot: snapshot_data
        )

        described_class.on_posture_change(project: project, old_posture: "conservative",
          new_posture: "conservative")

        expect(snapshot.reload.status).to eq("active")
      end
    end
  end

  describe "recovery decision routing" do
    it "includes snapshot and reason metadata in focused decision" do
      snapshot = AdmissionSnapshot.record(
        bounded_action: bounded_action,
        boundary: :queue,
        snapshot: snapshot_data
      )

      expect(Automation::FocusedDecision).to receive(:call).with(
        hash_including(
          metadata: hash_including(
            "snapshot_id" => snapshot.id,
            "action" => "review",
            "boundary" => "queue"
          )
        )
      )

      described_class.on_expiry(bounded_action: bounded_action)
    end

    it "handles focused decision failures gracefully" do
      snapshot = AdmissionSnapshot.record(
        bounded_action: bounded_action,
        boundary: :queue,
        snapshot: snapshot_data
      )

      allow(Automation::FocusedDecision).to receive(:call).and_raise("Decision failed")

      expect do
        described_class.on_expiry(bounded_action: bounded_action)
      end.not_to raise_error

      expect(snapshot.reload.status).to eq("rolled_back")
    end
  end
end
