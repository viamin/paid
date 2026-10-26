# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
  it "classifies the dedicated reopen provenance without interpreting its text" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    recovery = described_class.call(issue: issue)

    expect(recovery.primary_cause).to eq(:reopen_review)
    expect(recovery.action).to eq(:record_intent_validation)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps an unresolved dependency as a hold even when enhancement provenance exists" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: "parked")
    prerequisite = create(:issue, project: issue.project, github_state: "open")
    create(:issue_dependency, issue: issue, depends_on_issue: prerequisite)
    create(:agent_run, issue: issue, project: issue.project, goal: "enhance_issue", status: "failed")

    recovery = described_class.call(issue: issue)

    expect(recovery.causes).to include(:dependency, :enhancement)
    expect(recovery.primary_cause).to eq(:dependency)
    expect(recovery.action).to eq(:wait_for_dependency)
    expect(recovery.dependency_labels).to eq([ "##{prerequisite.github_number}" ])
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps unknown provenance visible and non-actionable" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: "An older integration parked this work.")

    recovery = described_class.call(issue: issue)

    expect(recovery.primary_cause).to eq(:unknown)
    expect(recovery.action).to eq(:investigate)
  end
end
