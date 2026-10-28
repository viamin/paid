# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::Recovery do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }
  let(:issue) { create(:issue, project:, paid_state: "manual_review") }

  # @spec OPERATOR-INBOX-002L ISSUE-REOPEN-REVIEW-005
  it "classifies the dedicated reopen gate without interpreting its text" do
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:reopen_review)
    expect(recovery.action).to eq(:record_reopen_review)
  end

  # @spec OPERATOR-INBOX-002L
  it "keeps an unresolved dependency waiting and identifies its owner work" do
    blocker = create(:issue, project:, github_number: 4321, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:dependency)
    expect(recovery.action).to eq(:wait_for_dependency)
    expect(recovery.dependencies).to contain_exactly(blocker)
  end

  # @spec OPERATOR-INBOX-002L
  it "routes scanner-confirmed recurrence to implementation recovery" do
    issue.update!(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:scanner_recurrence)
    expect(recovery.action).to eq(:resume_implementation)
  end

  # @spec OPERATOR-INBOX-002L
  it "keeps retryable scanner verification in its verifier wait" do
    issue.update!(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
    create(:code_scanning_remediation_attempt, issue:, status: "verification_blocked")

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:scanner_wait)
    expect(recovery.action).to eq(:wait_for_scanner)
  end

  # @spec OPERATOR-INBOX-002L
  it "preserves question answering for enhancement provenance" do
    issue.update!(needs_input_questions: [ "Which behavior is expected?" ])
    create(:agent_run, project:, issue:, goal: "enhance_issue")

    expect(described_class.call(issue:).action).to eq(:answer_questions)
  end

  # @spec OPERATOR-INBOX-002L
  it "retries enhancement only when the latest provenance is enhancement" do
    create(:agent_run, project:, issue:, goal: "enhance_issue", status: "failed")

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:enhancement_failure)
    expect(recovery.action).to eq(:retry_enhancement)
  end

  # @spec OPERATOR-INBOX-002L
  it "retains unknown causes visibly" do
    issue.update!(manual_review_reason: "An operator-attached reason")

    recovery = described_class.call(issue:)

    expect(recovery.cause).to eq(:unknown)
    expect(recovery.action).to eq(:none)
  end

  # @spec OPERATOR-INBOX-002L
  it "requires explicit reconciliation when incompatible work is active" do
    create(:agent_run, project:, issue:, goal: "create_pr", status: "queued")

    recovery = described_class.call(issue:)

    expect(recovery.action).to eq(:reconcile_active_run)
    expect(recovery.active_run.goal).to eq("create_pr")
  end
end
