# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:, paid_state: "manual_review") }

  # @spec OPERATOR-INBOX-002L
  it "recognizes the dedicated reopen-review provenance without inspecting reason text" do
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue:).kind).to eq(:reopen_review)
  end

  # @spec OPERATOR-INBOX-002L
  it "keeps an unresolved structured dependency actionable as a wait, not an enhancement retry" do
    blocker = create(:issue, project:, github_number: 4321, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    recovery = described_class.call(issue:)

    expect(recovery.kind).to eq(:dependency)
    expect(recovery.dependency).to eq(blocker)
  end

  # @spec OPERATOR-INBOX-002L
  it "recognizes scanner recurrence from its persisted verification attempt" do
    issue.update!(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    expect(described_class.call(issue:).kind).to eq(:scanner_recurrence)
  end

  # @spec OPERATOR-INBOX-002L
  it "keeps an unrecognized hold visibly unknown" do
    issue.update!(manual_review_reason: "A future producer parked this item.")

    expect(described_class.call(issue:).kind).to eq(:unknown)
  end
end
