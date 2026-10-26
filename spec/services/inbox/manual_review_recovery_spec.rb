# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  describe ".call" do
    let(:project) { create(:project) }

    # @spec OPERATOR-INBOX-002K ISSUE-REOPEN-REVIEW-005
    it "identifies the dedicated reopen-review hold without treating it as enhancement work" do
      issue = create(:issue, project:, paid_state: "manual_review",
        manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

      recovery = described_class.call(issue:)

      expect(recovery.cause).to eq(:reopen_review)
      expect(recovery.action).to eq(:record_reopen_validation)
      expect(recovery.retry_enhancement?).to be(false)
    end

    # @spec OPERATOR-INBOX-002K GITHUB-SYNC-016
    it "keeps a live dependency hold in place and names its owner" do
      blocker = create(:issue, project:, github_number: 4321, github_state: "open")
      issue = create(:issue, project:, paid_state: "manual_review",
        manual_review_reason: "Paid's agent run completed and opened a pull request, but this issue remains open and is blocked on an unresolved dependency: #4321.")
      issue.issue_dependencies.create!(depends_on_issue: blocker)

      recovery = described_class.call(issue:)

      expect(recovery.cause).to eq(:dependency_wait)
      expect(recovery.action).to eq(:wait_for_dependency)
      expect(recovery.references).to eq([ "#4321" ])
    end

    # @spec OPERATOR-INBOX-002K PARTIAL-CLOSEOUT-012
    it "routes a scanner-confirmed recurrence to scanner recovery" do
      issue = create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
        github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 1,
        paid_state: "manual_review")
      create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

      recovery = described_class.call(issue:)

      expect(recovery.cause).to eq(:scanner_recurrence)
      expect(recovery.action).to eq(:authorize_scanner_remediation)
    end

    # @spec OPERATOR-INBOX-002K ISSUE-ENHANCEMENT-011
    it "preserves enhancement retry for an enhancement-produced hold" do
      issue = create(:issue, project:, paid_state: "manual_review")
      create(:agent_run, project:, issue:, goal: "enhance_issue", status: "failed")

      expect(described_class.call(issue:).action).to eq(:retry_enhancement)
    end

    # @spec OPERATOR-INBOX-002K
    it "keeps an unproven hold visible instead of guessing a recovery" do
      issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "A human must investigate.")

      recovery = described_class.call(issue:)

      expect(recovery.cause).to eq(:unknown)
      expect(recovery.action).to eq(:investigate)
    end
  end
end
