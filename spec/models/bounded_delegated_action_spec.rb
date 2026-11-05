# frozen_string_literal: true

require "rails_helper"

# @spec BOUNDED-DELEGATED-ACTION-001 @spec BOUNDED-DELEGATED-ACTION-002
RSpec.describe BoundedDelegatedAction do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let(:user) { create(:user, account:) }

  it "requires bounded delivery evidence and an allowed action" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: user,
      evidence: { "intent_digest" => "sha256:abc", "acceptance_refs" => [ "AC-1" ] })

    expect(action).to be_valid
    expect(action.allowed?).to be(true)
  end

  it "rejects reserved product and release decisions" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: user,
      action: "release", evidence: { "intent_digest" => "sha256:abc" })

    expect(action).not_to be_valid
    expect(action.errors[:action]).to include("is not a delegable delivery action")
  end

  it "rejects evidence without an intent digest" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: user, evidence: {})

    expect(action).not_to be_valid
    expect(action.errors[:evidence]).to include("must include an intent_digest")
  end

  it "rejects evidence without acceptance references" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: user,
      evidence: { "intent_digest" => "sha256:abc" })

    expect(action).not_to be_valid
    expect(action.errors[:evidence]).to include("must include acceptance_refs")
  end

  it "rejects empty acceptance references" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: user,
      evidence: { "intent_digest" => "sha256:abc", "acceptance_refs" => [] })

    expect(action).not_to be_valid
    expect(action.errors[:evidence]).to include("must include acceptance_refs")
  end

  it "is terminal when revoked" do
    action = create(:bounded_delegated_action, project:, issue:, created_by: user)

    expect(action.revoke!(user:)).to be(true)
    expect(action.reload).to be_revoked
    expect(action.revoke!(user:)).to be(false)
  end

  it "rejects revocation by a user from another account" do
    action = create(:bounded_delegated_action, project:, issue:, created_by: user)
    other_user = create(:user)

    expect { action.revoke!(user: other_user) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(action.reload).to be_active
  end

  it "retains authorization history when its creator is destroyed" do
    action = create(:bounded_delegated_action, project:, issue:, created_by: user)

    user.destroy!

    expect(action.reload.created_by).to be_nil
  end

  it "is destroyed with its issue" do
    action = create(:bounded_delegated_action, project:, issue:, created_by: user)

    issue.destroy!

    expect(described_class.exists?(action.id)).to be(false)
  end

  it "does not block project deletion" do
    action = create(:bounded_delegated_action, project:, issue:, created_by: user)

    project.destroy!

    expect(described_class.exists?(action.id)).to be(false)
  end

  it "does not block account deletion" do
    action = create(:bounded_delegated_action, project:, issue:, created_by: user)

    account.destroy!

    expect(described_class.exists?(action.id)).to be(false)
  end
end
