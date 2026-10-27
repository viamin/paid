# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  def parked_issue(**attributes)
    create(:issue, { project:, github_state: "open", paid_state: "manual_review" }.merge(attributes))
  end

  # @spec OPERATOR-INBOX-002L ISSUE-REOPEN-REVIEW-005
  it "classifies reopen review from the dedicated persisted gate" do
    issue = parked_issue(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:reopen_review)
    expect(recovery.action).to eq(:record_reopen_validation)
  end

  # @spec OPERATOR-INBOX-002L
  it "holds a real unresolved dependency and exposes its owner" do
    blocker = create(:issue, project:, github_number: 4321, github_state: "open")
    issue = parked_issue(manual_review_reason: "Waiting")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:dependency)
    expect(recovery.action).to eq(:wait_for_dependency)
    expect(recovery.blockers.map(&:issue)).to eq([ blocker ])
  end

  # @spec OPERATOR-INBOX-002L
  it "classifies scanner recurrence from the synthetic scanner provenance" do
    issue = parked_issue(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)

    expect(described_class.call(issue:)).to have_attributes(cause: :scanner_recurrence, action: :collect_scanner_evidence)
  end

  # @spec OPERATOR-INBOX-002L
  it "classifies a known enhancement stop from run provenance" do
    issue = parked_issue
    create(:agent_run, project:, issue:, goal: "enhance_issue", status: "failed")

    expect(described_class.call(issue:)).to have_attributes(cause: :enhancement, action: :retry_enhancement)
  end

  # @spec OPERATOR-INBOX-002L
  it "keeps unknown provenance visible instead of guessing a retry" do
    issue = parked_issue(manual_review_reason: "Something happened")

    expect(described_class.call(issue:)).to have_attributes(cause: :unknown, action: :none)
  end

  # @spec OPERATOR-INBOX-002L ISSUE-REOPEN-REVIEW-005
  it "surfaces unfinished work before any continuation" do
    issue = parked_issue
    run = create(:agent_run, project:, issue:, goal: "analyze_issue", status: "queued")

    expect(described_class.call(issue:).active_run).to eq(run)
  end
end
