# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ResolveCloseout do # @spec PARTIAL-CLOSEOUT-006
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:project) { create(:project, account: account, owner: "acme", repo: "alpha") }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }

  def merged_partial_pr(number:)
    create(
      :issue,
      :pull_request,
      project: project,
      github_number: number,
      github_state: "closed",
      pr_review_phase: "merged",
      parent_issue_id: issue.id,
      created_at: 2.days.ago
    )
  end

  it "records the actor, reason, and evidence generation and completes the issue" do
    merged_partial_pr(number: 12)
    digest = Issues::CloseoutEvidence.call(issue).digest

    result = described_class.call(issue: issue, actor: user, reason: "Merged PR #12 covers the remainder.")

    expect(result.success?).to be(true)
    issue.reload
    expect(issue.paid_state).to eq("completed")
    expect(issue.closeout_resolved_at).to be_present
    expect(issue.closeout_resolution_digest).to eq(digest)
    expect(issue.closeout_resolved_by).to eq(user)
    expect(issue.github_state).to eq("open")
  end

  it "requires closeout evidence" do
    result = described_class.call(issue: issue, actor: user, reason: "done")

    expect(result.success?).to be(false)
    expect(result.code).to eq(:not_stalled)
    expect(issue.reload.paid_state).to eq("in_progress")
    expect(issue.closeout_resolved_at).to be_nil
  end

  it "requires a reason" do
    merged_partial_pr(number: 12)

    result = described_class.call(issue: issue, actor: user, reason: " ")

    expect(result.code).to eq(:invalid_reason)
  end

  it "records an audit event" do
    merged_partial_pr(number: 12)

    described_class.call(issue: issue, actor: user, reason: "Merged PR #12 covers the remainder.")

    event = account.account_activity_events.where(action: "issue.closeout_resolved").last
    expect(event).to be_present
    expect(event.actor).to eq(user)
    expect(event.subject).to eq(issue)
  end

  it "refuses a closed issue" do
    merged_partial_pr(number: 12)
    issue.update!(github_state: "closed", closed_at: Time.current)

    result = described_class.call(issue: issue.reload, actor: user, reason: "done")

    expect(result.success?).to be(false)
  end
end
