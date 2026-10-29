# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ResolveReopenReview do
  let(:project) { create(:project) }
  let(:actor) { project.created_by }
  let(:issue) do
    create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      github_updated_at: Time.current.change(usec: 0))
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "records an authorized current-revision decision without creating a run" do
    result = described_class.call(issue:, actor:, reason: "Closure evidence is incomplete.", revision: issue.github_updated_at.iso8601)

    expect(result).to be_success
    expect(issue.reload.paid_state).to eq("new")
    expect(AccountActivityEvent.last).to have_attributes(actor:, subject: issue, action: "issue.updated")
    expect(AccountActivityEvent.last.metadata).to include("reopen_review" => "resume_work", "revision" => issue.github_updated_at.iso8601)
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "retains the hold for a stale revision or active work" do
    stale = described_class.call(issue:, actor:, reason: "Need more work.", revision: "stale")
    expect(stale.status).to eq(:stale)
    expect(issue.reload).to be_reopen_review_pending

    create(:agent_run, project:, issue:, status: "queued")
    active = described_class.call(issue:, actor:, reason: "Need more work.", revision: issue.github_updated_at.iso8601)
    expect(active.status).to eq(:active_work)
    expect(issue.reload).to be_reopen_review_pending
  end
end
