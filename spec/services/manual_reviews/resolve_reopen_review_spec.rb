# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::ResolveReopenReview do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account:) }
  let(:project) { create(:project, account:) }
  let(:issue) do
    create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "records an authorized revision-bound continuation decision" do
    result = described_class.call(issue:, actor:, decision: "resume", reason: "The regression remains open.")

    expect(result).to be_success
    event = AccountActivityEvent.order(:id).last
    expect(event).to have_attributes(account:, actor:, subject: issue, action: "issue.updated")
    expect(event.metadata).to include("reopen_review_decision" => "resume", "revision" => issue.github_updated_at.iso8601)
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "rejects blank reasons without clearing the gate" do
    result = described_class.call(issue:, actor:, decision: "resume", reason: "")

    expect(result).not_to be_success
    expect(issue.reload).to be_reopen_review_pending
  end
end
