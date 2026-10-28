# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ManualReviewRecovery do
  # @spec ISSUE-REOPEN-REVIEW-005
  it "prefers the reopen gate over an arbitrary human-readable reason" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue: issue).kind).to eq(:reopen_review)
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "does not infer enhancement recovery for unknown provenance" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: "operator supplied context")

    expect(described_class.call(issue: issue).kind).to eq(:unknown)
  end
end
