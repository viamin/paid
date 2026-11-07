# frozen_string_literal: true

require "rails_helper"

RSpec.describe AdmissionSnapshot do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let(:user) { create(:user, account:) }
  let(:authorization) { create(:bounded_delegated_action, project:, issue:) }

  it { is_expected.to belong_to(:account) }
  it { is_expected.to belong_to(:project) }
  it { is_expected.to belong_to(:issue) }
  it { is_expected.to belong_to(:bounded_delegated_action) }

  it "validates boundary is one of the allowed boundaries" do
    snapshot = build(:admission_snapshot, boundary: "invalid")
    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:boundary]).to include("is not included in the list")
  end

  it "validates status is one of the allowed statuses" do
    snapshot = build(:admission_snapshot, status: "invalid")
    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:status]).to include("is not included in the list")
  end

  it "validates snapshot is an object" do
    snapshot = build(:admission_snapshot, snapshot: "not an object")
    expect(snapshot).not_to be_valid
    expect(snapshot.errors[:snapshot]).to include("must be an object")
  end

  it "is active when status is active and not expired" do
    snapshot = create(:admission_snapshot, status: "active", expires_at: 1.day.from_now)
    expect(snapshot.active?).to be(true)
  end

  it "is not active when status is rolled back" do
    snapshot = create(:admission_snapshot, status: "rolled_back")
    expect(snapshot.active?).to be(false)
  end

  it "is not active when expired" do
    snapshot = create(:admission_snapshot, status: "active", expires_at: 1.day.ago)
    expect(snapshot.active?).to be(false)
  end

  it "is active regardless of expiry when expires_at is nil" do
    snapshot = create(:admission_snapshot, status: "active", expires_at: nil)
    expect(snapshot.active?).to be(true)
  end

  it "allows rollback of active snapshots" do
    snapshot = create(:admission_snapshot, status: "active")

    expect(snapshot.rollback!(reason: "Policy changed", user:)).to be(true)
    expect(snapshot.reload).to have_attributes(status: "rolled_back", rollback_reason: "Policy changed")
  end

  it "records audit event when rolling back" do
    snapshot = create(:admission_snapshot, status: "active", bounded_delegated_action: authorization)

    expect(snapshot.rollback!(reason: "Policy narrowed", user:)).to be(true)
    expect(snapshot.reload).to have_attributes(status: "rolled_back", rollback_reason: "Policy narrowed")

    # Verify audit event was created
    expect(AccountActivityEvent.by_action("admission_snapshot.rolled_back").count).to be > 0
  end

  it "does not rollback an already-rolled-back snapshot" do
    snapshot = create(:admission_snapshot, status: "rolled_back")

    expect(snapshot.rollback!(reason: "Late attempt", user:)).to be(false)
    expect(snapshot.reload.status).to eq("rolled_back")
  end

  describe "scopes" do
    it "finds active snapshots" do
      active = create(:admission_snapshot, status: "active", expires_at: 1.day.from_now)
      rolled_back = create(:admission_snapshot, status: "rolled_back")
      expired = create(:admission_snapshot, status: "active", expires_at: 1.day.ago)

      expect(described_class.active).to include(active)
      expect(described_class.active).not_to include(rolled_back, expired)
    end
  end
end
