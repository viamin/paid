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

  it "is terminal when revoked" do
    action = create(:bounded_delegated_action, project:, issue:, created_by: user)

    expect(action.revoke!(user:)).to be(true)
    expect(action.reload).to be_revoked
    expect(action.revoke!(user:)).to be(false)
  end
end
