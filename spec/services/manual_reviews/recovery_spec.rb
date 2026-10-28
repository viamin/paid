# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::Recovery do
  # @spec ISSUE-REOPEN-REVIEW-005
  it "classifies the dedicated reopen-review provenance before any other hold" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:reopen_review)
    expect(recovery).to be_records_decision
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps a real dependency wait visible instead of offering an enhancement retry" do
    issue = create(:issue, paid_state: "manual_review")
    blocker = create(:issue, project: issue.project, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:dependency_wait)
    expect(recovery).not_to be_resumes_implementation
    expect(recovery.blockers).to contain_exactly(blocker)
  end

  # @spec OPERATOR-INBOX-002D
  it "routes a scanner-confirmed recurrence to scanner evidence, not enhancement" do
    issue = create(:issue, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE, paid_state: "manual_review")
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    expect(described_class.call(issue:).cause).to eq(:scanner_recurrence)
  end

  # @spec ISSUE-ENHANCEMENT-011
  it "preserves enhancement retry only for enhancement provenance" do
    issue = create(:issue, paid_state: "manual_review")
    create(:agent_run, project: issue.project, issue:, goal: "enhance_issue", status: "failed")

    expect(described_class.call(issue:)).to be_retries_enhancement
  end

  # @spec OPERATOR-INBOX-002D
  it "retains unknown provenance visibly without inventing a retry action" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: "Unrecognized operator hold")

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:unknown)
    expect(recovery).not_to be_resumes_implementation
  end
end
