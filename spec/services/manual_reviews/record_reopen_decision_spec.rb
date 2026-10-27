# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::RecordReopenDecision do
  let(:actor) { create(:user) }
  let(:issue) do
    create(:issue, project: create(:project, account: actor.account), paid_state: "manual_review",
      github_state: "open", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      github_updated_at: Time.current)
  end

  # @spec ISSUE-REOPEN-REVIEW-006
  it "records an authorized reason against the current issue revision" do
    described_class.call(issue: issue, actor: actor, action: "retry_analysis", reason: "Evidence is incomplete",
      revision: issue.github_updated_at.iso8601)

    expect(issue.reload).to have_attributes(
      reopen_review_decision: "retry_analysis",
      reopen_review_decision_reason: "Evidence is incomplete",
      reopen_review_decided_by: actor,
      reopen_review_revision: issue.github_updated_at.iso8601
    )
  end

  # @spec ISSUE-REOPEN-REVIEW-006
  it "rejects stale reopen evidence" do
    expect {
      described_class.call(issue: issue, actor: actor, action: "retry_analysis", reason: "Evidence is incomplete",
        revision: 1.minute.ago.iso8601)
    }.to raise_error(described_class::StaleRevisionError)
  end
end
