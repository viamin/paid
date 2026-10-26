# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ManualReviewRecovery do
  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
  it "classifies the dedicated reopen-review provenance without parsing its display reason" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue:).cause).to eq(:reopen_review)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps an otherwise unprovenanced manual-review hold visible as unknown" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: "An operator note")

    expect(described_class.call(issue:).cause).to eq(:unknown)
  end

  # @spec OPERATOR-INBOX-002D
  it "classifies a live dependency from the dependency records" do
    issue = create(:issue, paid_state: "manual_review")
    blocker = create(:issue, project: issue.project, github_state: "open")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    result = described_class.call(issue:)
    expect(result.cause).to eq(:dependency)
    expect(result.blockers).to include(blocker)
  end
end
