# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:project) { create(:project) }

  # @spec MANUAL-REVIEW-RECOVERY-001
  it "classifies reopen review from its dedicated provenance" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue).cause).to eq(:reopen_review)
  end

  # @spec MANUAL-REVIEW-RECOVERY-002
  it "keeps an unresolved dependency distinct from an enhancement stop" do
    blocker = create(:issue, project:, github_number: 4321, github_state: "open")
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Waiting for #4321")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    recovery = described_class.call(issue)

    expect(recovery.cause).to eq(:dependency)
    expect(recovery.dependency).to eq(blocker)
    expect(recovery.resumable?).to be(false)
  end

  # @spec MANUAL-REVIEW-RECOVERY-003
  it "routes scanner recurrence from durable scanner provenance" do
    issue = create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      paid_state: "manual_review", manual_review_reason: "scanner-confirmed recurrence")

    expect(described_class.call(issue).cause).to eq(:scanner_recurrence)
  end

  # @spec MANUAL-REVIEW-RECOVERY-004
  it "keeps an unclassified hold visible and non-resumable" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "An operator supplied reason")

    recovery = described_class.call(issue)

    expect(recovery.cause).to eq(:unknown)
    expect(recovery.resumable?).to be(false)
  end
end
