# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ManualReviewRecovery do
  let(:project) { create(:project) }

  # @spec OPERATOR-INBOX-002K
  it "classifies a reopen hold from its dedicated provenance" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue:).cause).to eq(:reopen_review)
  end

  # @spec OPERATOR-INBOX-002K
  it "keeps unclassified holds visibly unknown" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: nil)

    expect(described_class.call(issue:)).to be_unknown
  end

  # @spec OPERATOR-INBOX-002K
  it "classifies an unresolved dependency before enhancement history" do
    dependency = create(:issue, project:, github_state: "open")
    issue = create(:issue, project:, paid_state: "manual_review")
    create(:issue_dependency, issue:, depends_on_issue: dependency)
    create(:agent_run, project:, issue:, goal: "enhance_issue", status: "failed")

    expect(described_class.call(issue:).cause).to eq(:dependency_wait)
  end

  # @spec OPERATOR-INBOX-002K
  it "classifies a scanner-confirmed recurrence" do
    issue = create(:issue, project:, paid_state: "manual_review", source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    expect(described_class.call(issue:).cause).to eq(:scanner_recurrence)
  end

  # @spec OPERATOR-INBOX-002K
  it "describes a queued run as reuse instead of another recovery action" do
    issue = create(:issue, project:, paid_state: "manual_review")
    create(:agent_run, project:, issue:, goal: "create_pr", status: "queued")

    expect(described_class.call(issue:).action).to eq(:reuse_active_run)
  end
end
