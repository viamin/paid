# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ResolveReopenReview do
  let(:issue) do
    create(:issue, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      github_updated_at: Time.current.change(usec: 0))
  end
  let(:actor) { create(:user, account: issue.project.account) }

  # @spec ISSUE-REOPEN-REVIEW-005
  it "records an audit decision bound to the current synchronized revision without creating a run" do
    run_count = AgentRun.count
    expect {
      described_class.call(issue:, actor:, decision: "collect_evidence", reason: "Live artifacts remain uncollected.",
        revision: issue.github_updated_at.iso8601)
    }.to change(AccountActivityEvent, :count).by(1)
    expect(AgentRun.count).to eq(run_count)

    expect(issue.reload.paid_state).to eq("new")
    event = AccountActivityEvent.last
    expect(event.action).to eq("issue.reopen_review_resolved")
    expect(event.metadata).to include("decision" => "collect_evidence", "revision" => issue.github_updated_at.iso8601)
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "rejects a stale revision and retains the hold" do
    expect {
      described_class.call(issue:, actor:, decision: "resume_implementation", reason: "Scope remains valid.", revision: "stale")
    }.to raise_error(described_class::Error, /changed/)

    expect(issue.reload).to be_reopen_review_pending
  end
end
