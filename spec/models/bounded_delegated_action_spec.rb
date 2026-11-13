# frozen_string_literal: true

require "rails_helper"

# @spec BOUNDED-PHASE-AUTHORIZATION-010 @spec BOUNDED-PHASE-AUTHORIZATION-011
RSpec.describe BoundedDelegatedAction do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:) }
  let(:user) { create(:user, account:) }
  let(:intent_digest) { "sha256:#{Digest::SHA256.hexdigest('intent')}" }

  it "requires bounded delivery evidence and an allowed action" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: user,
      evidence: { "intent_digest" => intent_digest, "acceptance_refs" => [ "AC-1" ] })

    expect(action).to be_valid
    expect(action.allowed?).to be(true)
  end

  it "rejects reserved product and release decisions" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: user,
      action: "release", evidence: { "intent_digest" => intent_digest })

    expect(action).not_to be_valid
    expect(action.errors[:action]).to include("is not a delegable delivery action")
  end

  it "rejects evidence without an intent digest" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: user, evidence: {})

    expect(action).not_to be_valid
    expect(action.errors[:evidence]).to include("must include an intent_digest")
  end

  it "rejects a truthy intent digest that is not a sha256 digest" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: user,
      evidence: { "intent_digest" => true, "acceptance_refs" => [ "AC-1" ] })

    expect(action).not_to be_valid
    expect(action.errors[:evidence]).to include("intent_digest must be a sha256:<64 hex characters> digest")
  end

  it "rejects an intent digest with a malformed sha256 form" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: user,
      evidence: { "intent_digest" => "sha256:abc", "acceptance_refs" => [ "AC-1" ] })

    expect(action).not_to be_valid
    expect(action.errors[:evidence]).to include("intent_digest must be a sha256:<64 hex characters> digest")
  end

  it "rejects evidence without acceptance references" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: user,
      evidence: { "intent_digest" => intent_digest })

    expect(action).not_to be_valid
    expect(action.errors[:evidence]).to include("must include acceptance_refs")
  end

  it "rejects empty acceptance references" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: user,
      evidence: { "intent_digest" => intent_digest, "acceptance_refs" => [] })

    expect(action).not_to be_valid
    expect(action.errors[:evidence]).to include("must include acceptance_refs")
  end

  it "rejects a project from another account" do
    other_project = create(:project)
    action = build(:bounded_delegated_action, account: account, project: other_project,
      issue: create(:issue, project: other_project), created_by: user)

    expect(action).not_to be_valid
    expect(action.errors[:account]).to include("must match the project")
  end

  it "rejects an issue from another project" do
    other_issue = create(:issue, project: create(:project, account:))

    action = build(:bounded_delegated_action, project:, issue: other_issue, created_by: user)

    expect(action).not_to be_valid
    expect(action.errors[:issue]).to include("must belong to the project")
  end

  it "rejects a creator from another account" do
    action = build(:bounded_delegated_action, project:, issue:, created_by: create(:user))

    expect(action).not_to be_valid
    expect(action.errors[:created_by]).to include("must belong to the account")
  end

  it "is terminal when revoked" do
    action = create(:bounded_delegated_action, project:, issue:, created_by: user)

    expect(action.revoke!(user:)).to be(true)
    expect(action.reload).to be_revoked
    expect(action.allowed?).to be(false)
    expect(action.revoke!(user:)).to be(false)
  end

  it "records an account activity event when revoked" do
    action = create(:bounded_delegated_action, project:, issue:, created_by: user)

    action.revoke!(user:)

    event = account.account_activity_events.by_action("bounded_action.revoked").last
    expect(event).to have_attributes(actor: user, subject: action)
    expect(event.metadata).to include("action" => "repair")
  end

  it "does not allow an expired authorization" do
    action = create(:bounded_delegated_action, project:, issue:, created_by: user, expires_at: 1.minute.ago)

    expect(action).not_to be_active
    expect(action).not_to be_allowed
  end

  it "exposes its persisted evidence as the immutable admission snapshot" do # @spec PROJECT-DELEGATION-004
    action = create(:bounded_delegated_action, project:, issue:, created_by: user)

    expect(action.admission_snapshot).to eq(action.evidence)
    expect(action.admission_snapshot).not_to be(action.evidence)
  end

  it "rejects changes to persisted admission evidence" do # @spec PROJECT-DELEGATION-004
    action = create(:bounded_delegated_action, project:, issue:, created_by: user)

    expect {
      action.update!(evidence: action.evidence.merge("posture_signature" => "replacement"))
    }.to raise_error(ActiveRecord::RecordInvalid, "Validation failed: Evidence cannot be changed after admission")
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
