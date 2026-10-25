# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::RecordReopenDecision do
  let(:project) { create(:project) }
  let(:actor) { project.created_by }
  let(:issue) do
    create(:issue, project: project, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      github_updated_at: Time.current)
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "records an actor-bound decision for the exact synchronized revision" do
    described_class.call(issue: issue, actor: actor, decision: "complete", reason: "The closure still covers all scope.",
      evidence_revision: issue.github_updated_at.iso8601)

    expect(issue.reload.paid_state).to eq("completed")
    expect(AccountActivityEvent.last).to have_attributes(actor: actor, subject: issue, action: "issue.reopen_review_decided")
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "rejects a stale evidence revision without clearing the hold" do
    expect {
      described_class.call(issue: issue, actor: actor, decision: "resume_work", reason: "Regression remains.",
        evidence_revision: 1.minute.ago.iso8601)
    }.to raise_error(ArgumentError, /issue changed/)

    expect(issue.reload).to be_reopen_review_pending
  end
end
