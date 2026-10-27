# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:project) { create(:project) }

  # @spec ISSUE-REOPEN-REVIEW-005
  it "classifies a reopen hold from its dedicated provenance, not its copy" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:reopen_review)
    expect(recovery.action).to eq(:record_intent_validation)
  end

  # @spec GITHUB-SYNC-017
  it "keeps a real unresolved dependency waiting and exposes its owner" do
    blocker = create(:issue, project:, github_number: 4321, github_state: "open")
    issue = create(:issue, project:, paid_state: "manual_review")
    issue.issue_dependencies.create!(depends_on_issue: blocker)

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:dependency)
    expect(recovery.blockers).to contain_exactly(blocker)
    expect(recovery.action).to eq(:wait_for_dependency)
  end

  # @spec ISSUE-ENHANCEMENT-011
  it "classifies enhancement retry from a persisted enhancement run" do
    issue = create(:issue, project:, paid_state: "manual_review")
    create(:agent_run, project:, issue:, goal: "enhance_issue", status: "failed")

    expect(described_class.call(issue:).cause).to eq(:enhancement)
  end

  # @spec PARTIAL-CLOSEOUT-012
  it "classifies scanner recurrence from scanner provenance" do
    issue = create(:issue, project:, paid_state: "manual_review", source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    expect(described_class.call(issue:).cause).to eq(:scanner_recurrence)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps unsupported provenance visible as unknown" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "legacy stop")

    expect(described_class.call(issue:).cause).to eq(:unknown)
  end
end
