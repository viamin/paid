# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  # @spec OPERATOR-INBOX-002H ISSUE-REOPEN-REVIEW-005
  it "classifies reopen review from its dedicated persisted provenance" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      reopen_reason: "Validation evidence was not collected")

    recovery = described_class.call(issue)

    expect(recovery).to have_attributes(cause: :reopen_review, action: :analyze_issue)
    expect(recovery.summary).to include("Validation evidence was not collected")
  end

  # @spec OPERATOR-INBOX-002H
  it "keeps an unresolved dependency as a wait instead of offering enhancement" do
    blocker = create(:issue, project:, github_number: 4321, github_state: "open")
    issue = create(:issue, project:, paid_state: "manual_review")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    recovery = described_class.call(issue)

    expect(recovery).to have_attributes(cause: :dependency, action: :wait_for_dependency)
    expect(recovery.dependencies).to eq([ blocker ])
  end

  # @spec OPERATOR-INBOX-002H
  it "routes scanner recurrence to remediation" do
    issue = create(:issue, project:, paid_state: "manual_review", source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    expect(described_class.call(issue)).to have_attributes(cause: :scanner_recurrence, action: :create_pr)
  end

  # @spec OPERATOR-INBOX-002H
  it "retains an unknown manual-review cause visibly" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Legacy operator hold")

    expect(described_class.call(issue)).to have_attributes(cause: :unknown, action: :none)
  end

  # @spec OPERATOR-INBOX-002H
  it "routes a classified technical failure to analysis recovery" do
    issue = create(:issue, project:, paid_state: "manual_review")
    run = create(:agent_run, project:, issue:, status: "failed", goal: "create_pr")
    create(:failure_classification, agent_run: run, project:)

    expect(described_class.call(issue)).to have_attributes(cause: :technical_failure, action: :analyze_issue)
  end
end
