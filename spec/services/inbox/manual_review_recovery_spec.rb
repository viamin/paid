# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:project) { create(:project) }

  # @spec OPERATOR-INBOX-002L
  it "classifies the dedicated reopen-review provenance before other recovery paths" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue:).kind).to eq(:reopen_review)
  end

  # @spec OPERATOR-INBOX-002L
  it "classifies a real unresolved dependency without parsing its reason" do
    dependency = create(:issue, project:, github_state: "open")
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "unrelated text")
    issue.issue_dependencies.create!(depends_on_issue: dependency)

    recovery = described_class.call(issue:)

    expect(recovery.kind).to eq(:dependency)
    expect(recovery.dependency).to eq(dependency)
  end

  # @spec OPERATOR-INBOX-002L
  it "classifies a scanner recurrence from its remediation attempt" do
    issue = create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      paid_state: "manual_review")
    create(:code_scanning_remediation_attempt, issue:, status: "verification_blocked")

    expect(described_class.call(issue:).kind).to eq(:scanner)
  end

  # @spec OPERATOR-INBOX-002L
  it "keeps an unprovenanced manual-review hold visibly unknown" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "operator note")

    expect(described_class.call(issue:).kind).to eq(:unknown)
  end
end
