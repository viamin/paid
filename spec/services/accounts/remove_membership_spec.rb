# frozen_string_literal: true

require "rails_helper"

RSpec.describe Accounts::RemoveMembership do
  let(:account) { create(:account) }
  let(:owner) { create(:user, :owner, account:) }
  let(:member) { create(:user, :member, account:) }
  let(:project) { create(:project, account:, created_by: owner, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "in_progress") }

  before do
    owner
    member
  end

  def merged_partial_pr
    create(:issue, :pull_request, project:, github_number: 5413, github_state: "closed",
      pr_review_phase: "merged", parent_issue: issue, created_at: 2.days.ago)
  end

  def remove_member
    described_class.call(account:, membership: member.account_membership_for(account), actor: owner)
  end

  def acceptance_audit
    merged_partial_pr
    result = Issues::RequestAcceptanceAudit.call(issue:, actor: member)
    expect(result).to be_success
    result
  end

  # @spec ACCOUNT-ADMIN-005 TENANT-ACCESS-003 PARTIAL-CLOSEOUT-064
  it "removes the last member after a queued acceptance audit while preserving request and run lineage" do
    audit = acceptance_audit

    expect { remove_member }.not_to raise_error

    request = audit.request.reload
    expect(member.id).not_to be_in(User.pluck(:id))
    expect(request).to have_attributes(requested_by_id: nil, status: "queued")
    expect(audit.agent_run.reload).to have_attributes(continuation_request_id: request.id, status: "queued")
    expect(AgentRuns::RecheckIssueEligibility.call(audit.agent_run)).to be(true)
    expect(request.reload.status).to eq("superseded")
  end

  # @spec ACCOUNT-ADMIN-005 PARTIAL-CLOSEOUT-064
  it "uses database nullifying foreign keys for preserved historical actors" do
    audit = acceptance_audit
    pull_request = create(:issue, :pull_request, project:, github_number: 5414, github_state: "closed",
      pr_review_phase: "merged", github_html_url: "https://github.com/acme/alpha/pull/5414",
      merged_commit_sha: "c" * 40)
    association = Issues::AssociateSharedDeliveryEvidence.call(issue:, pull_request:, actor: member)

    member.account_memberships.destroy_all
    member.account_activity_events.update_all(actor_id: nil)
    User.delete(member.id)

    expect(audit.request.reload.requested_by_id).to be_nil
    expect(association.reload.authorized_by_id).to be_nil
  end

  # @spec ACCOUNT-ADMIN-005 PARTIAL-CLOSEOUT-064
  it "removes the last member after a consumed acceptance audit while preserving its history" do
    audit = acceptance_audit
    audit.request.consume!(run_status: "completed")

    expect { remove_member }.not_to raise_error

    expect(audit.request.reload).to have_attributes(requested_by_id: nil, status: "consumed")
    expect(audit.agent_run.reload.continuation_request_id).to eq(audit.request.id)
  end

  # @spec ACCOUNT-ADMIN-005 TENANT-ACCESS-003 PARTIAL-CLOSEOUT-064
  it "retains live shared-delivery lineage but fails it closed after revocation" do
    pull_request = create(:issue, :pull_request, project:, github_number: 5319, github_state: "closed",
      pr_review_phase: "merged", github_html_url: "https://github.com/acme/alpha/pull/5319",
      merged_commit_sha: "a" * 40)
    association = Issues::AssociateSharedDeliveryEvidence.call(issue:, pull_request:, actor: member)
    audit = Issues::RequestAcceptanceAudit.call(issue:, actor: member)

    expect(audit).to be_success
    expect { remove_member }.not_to raise_error

    expect(association.reload).to have_attributes(authorized_by_id: nil, revoked_at: nil)
    expect(association).not_to be_current
    expect(Issues::CloseoutEvidence.call(issue)).not_to be_present
    expect(AgentRuns::RecheckIssueEligibility.call(audit.agent_run)).to be(true)
    expect(audit.request.reload.status).to eq("superseded")
  end

  # @spec ACCOUNT-ADMIN-005 PARTIAL-CLOSEOUT-064
  it "retains revoked shared-delivery history after removing its authorizer" do
    pull_request = create(:issue, :pull_request, project:, github_number: 5320, github_state: "closed",
      pr_review_phase: "merged", github_html_url: "https://github.com/acme/alpha/pull/5320",
      merged_commit_sha: "b" * 40)
    association = Issues::AssociateSharedDeliveryEvidence.call(issue:, pull_request:, actor: member)
    association.update!(revoked_at: Time.current)

    expect { remove_member }.not_to raise_error

    expect(association.reload).to have_attributes(authorized_by_id: nil, revoked_at: be_present)
    expect(association).not_to be_current
  end

  # @spec ACCOUNT-ADMIN-005 PARTIAL-CLOSEOUT-064
  it "keeps a successor-account user when no historical artifacts exist" do
    successor_account = create(:account)
    member.add_role(:member, successor_account)
    expect { remove_member }.not_to change(User, :count)

    expect(member.reload.account).to eq(successor_account)
    expect(member.account_membership_for(account)).to be_nil
  end

  it "cancels an audit after its requester moves to a successor account without rewriting history" do # @spec PARTIAL-CLOSEOUT-064 TENANT-ACCESS-003
    audit = acceptance_audit
    original = audit.agent_run.attributes.slice("initiating_user_id", "project_id", "issue_id",
      "continuation_request_id", "trigger_type", "runner_id", "external_metadata")
    successor_account = create(:account)
    member.add_role(:member, successor_account)

    remove_member

    expect(member.reload.account).to eq(successor_account)
    expect(AgentRuns::RecheckIssueEligibility.call(audit.agent_run)).to be(true)
    expect(audit.agent_run.reload.status).to eq("cancelled")
    expect(audit.agent_run.attributes.slice(*original.keys)).to eq(original)
    expect(audit.request.reload.status).to eq("superseded")
  end

  # @spec ACCOUNT-ADMIN-005 PARTIAL-CLOSEOUT-064
  it "removes the last member without historical artifacts" do
    expect { remove_member }.to change(User, :count).by(-1)
    expect(AccountMembership.where(account:, user_id: member.id)).to be_empty
  end
end
