# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::RemoveMembership do # @spec AUTO-MERGE-011
  let(:owner) { create(:user) }
  let(:account) { owner.account }
  let(:requester) { create(:user, :member, account:) }
  let(:membership) { requester.account_memberships.find_by!(account:) }
  let(:project) { create(:project, account:, created_by: owner) }
  let(:issue) { create(:issue, :pull_request, project:, github_number: 42) }
  let(:producer) do
    create(:agent_run, :automatic, :failed, project:, issue:, goal: "create_pr", focus: "merge_conflict",
      source_pull_request_number: 42, result_commit_sha: "result-sha",
      external_metadata: { "pre_run_head_sha" => "pre-sha" })
  end

  it "revokes a requester's final membership while retaining the artifact decision" do
    evidence = create_scope_evidence(requested_by: requester)
    original = evidence.attributes.except("requested_by_id", "updated_at")
    requester_id = requester.id
    membership_id = membership.id

    described_class.call(account:, membership:, actor: owner)

    expect(User.exists?(requester_id)).to be(false)
    expect(AccountMembership.exists?(membership_id)).to be(false)
    expect(evidence.reload.requested_by_id).to be_nil
    expect(evidence.attributes.except("requested_by_id", "updated_at")).to eq(original)
    expect(producer.reload).to have_attributes(status: "failed", result_commit_sha: "result-sha")
  end

  it "nullifies historical attribution for database deletion without model callbacks" do
    # No callbacks or child records: this isolates the foreign key's actual
    # referential action from User's dependent-association behavior.
    requester_id = User.insert!({ account_id: account.id,
      email: "historical-#{SecureRandom.hex(8)}@example.com", name: "Historical requester",
      encrypted_password: "", created_at: Time.current, updated_at: Time.current }).rows.first.first
    evidence = create_scope_evidence(requested_by: User.find(requester_id))
    original = evidence.attributes.except("requested_by_id", "updated_at")

    expect { User.where(id: requester_id).delete_all }.to change(User, :count).by(-1)

    expect(evidence.reload.requested_by_id).to be_nil
    expect(evidence.attributes.except("requested_by_id", "updated_at")).to eq(original)
  end

  it "keeps historical attribution when the user retains a different account membership" do
    other_account = create(:account)
    create(:account_membership, user: requester, account: other_account, role: "member")
    evidence = create_scope_evidence(requested_by: requester)
    requester_id = requester.id
    membership_id = membership.id

    described_class.call(account:, membership:, actor: owner)

    expect(requester.reload.account).to eq(other_account)
    expect(AccountMembership.exists?(membership_id)).to be(false)
    expect(evidence.reload.requested_by_id).to eq(requester_id)
    expect(requester.has_role?(:member, account)).to be(false)
    expect(producer.reload).to have_attributes(status: "failed", result_commit_sha: "result-sha")
  end

  def create_scope_evidence(requested_by:)
    ConflictRepairScopeEvidence.create!(agent_run: producer, account:, project:, issue:, requested_by:,
      pre_run_sha: "pre-sha", integration_base_sha: "base-sha", result_sha: "result-sha", provider_head_sha: "result-sha",
      status: "approved", explanation: "Historical bounded repair decision", base_imported_paths: [], repair_authored_paths: [])
  end
end
