# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:project) { create(:project) }

  # @spec OPERATOR-INBOX-002L @spec ISSUE-REOPEN-REVIEW-005
  it "requires an intent-validation decision for the explicit reopen provenance" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    result = described_class.call(issue:)

    expect(result.causes).to eq([ :reopen_review ])
    expect(result.action).to eq(:validate_reopen_intent)
    expect(result.goal).to eq("enhance_issue")
  end

  # @spec OPERATOR-INBOX-002L
  it "keeps an unresolved dependency as a wait even when enhancement provenance also exists" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Round limit reached.")
    blocker = create(:issue, project:, github_state: "open", title: "Dependency")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    result = described_class.call(issue:)

    expect(result.causes).to include(:dependency_wait, :enhancement)
    expect(result.action).to eq(:wait_for_dependency)
    expect(result.dependencies.map(&:label)).to include("##{blocker.github_number} Dependency")
  end

  # @spec OPERATOR-INBOX-002L @spec PARTIAL-CLOSEOUT-012
  it "routes a scanner-confirmed recurrence to remediation rather than enhancement" do
    issue = create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      paid_state: "manual_review", github_state: "open")
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    result = described_class.call(issue:)

    expect(result.action).to eq(:resume_scanner_remediation)
    expect(result.goal).to eq("create_pr")
  end

  # @spec OPERATOR-INBOX-002L
  it "retains an unclassified hold visibly without guessing a retry" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Operator investigation required")

    result = described_class.call(issue:)

    expect(result.causes).to eq([ :unknown ])
    expect(result.action).to eq(:investigate)
    expect(result.goal).to be_nil
  end

  # @spec OPERATOR-INBOX-002L
  it "reuses the latest implementation goal for a technical hold" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Runner transport failed")
    create(:agent_run, project:, issue:, goal: "create_pr", status: "failed")

    result = described_class.call(issue:)

    expect(result.action).to eq(:resume_implementation)
    expect(result.goal).to eq("create_pr")
  end
end
