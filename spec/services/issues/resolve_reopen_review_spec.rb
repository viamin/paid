# frozen_string_literal: true

require "rails_helper"

# @spec ISSUE-REOPEN-REVIEW-005
RSpec.describe Issues::ResolveReopenReview do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) do
    create(:issue, project:, github_state: "open", paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)
  end
  let(:revision) { issue.github_updated_at.utc.iso8601 }

  it "records a valid decision and releases the review gate" do
    expect {
      described_class.call(issue:, actor: user, decision: "valid", reason: "The remaining scope is still required.", revision:)
    }.to change { account.account_activity_events.where(action: "issue.updated").count }.by(1)

    expect(issue.reload.paid_state).to eq("in_progress")
  end

  it "keeps review open when the intent needs changes" do
    result = described_class.call(issue:, actor: user, decision: "needs_changes", reason: "The scope changed.", revision:)

    expect(result).to be_success
    expect(issue.reload).to be_reopen_review_pending
  end

  it "rejects a stale revision without changing the hold" do
    result = described_class.call(issue:, actor: user, decision: "valid", reason: "Reviewed.", revision: "stale")

    expect(result).not_to be_success
    expect(issue.reload).to be_reopen_review_pending
  end
end
