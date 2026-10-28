# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Review required") }

  # @spec ISSUE-REOPEN-REVIEW-005 @spec OPERATOR-INBOX-002D
  it "classifies reopen review from its dedicated persisted reason" do
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON, reopen_reason: "Validation was missing")

    snapshot = described_class.call(issue)

    expect(snapshot.primary.type).to eq(:reopen_review)
    expect(snapshot.primary.evidence).to include(reopen_reason: "Validation was missing")
    expect(snapshot.action).to eq(:record_reopen_decision)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps an unresolved dependency non-waivable and links its owner" do
    dependency = create(:issue, project:, github_number: 4321, github_state: "open")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    snapshot = described_class.call(issue)

    expect(snapshot.causes.map(&:type)).to include(:dependency)
    expect(snapshot.primary.action).to be_nil
    expect(snapshot.primary.links).to include(hash_including(label: "Issue #4321"))
  end

  # @spec ISSUE-ENHANCEMENT-011 @spec OPERATOR-INBOX-002D
  it "preserves enhancement recovery when questions exist" do
    issue.update!(needs_input_questions: [ "Which behavior is required?" ])

    expect(described_class.call(issue).action).to eq(:retry_analysis)
  end

  # @spec OPERATOR-INBOX-002D
  it "routes scanner recurrence to implementation with scanner evidence" do
    issue.update!(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 17)
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    cause = described_class.call(issue).primary

    expect(cause.type).to eq(:scanner_recurrence)
    expect(cause.action).to eq(:resume_implementation)
    expect(cause.evidence).to include("alert_number" => 17, "recurrent" => true)
  end

  # @spec OPERATOR-INBOX-002D
  it "routes a failed implementation run back to implementation" do
    run = create(:agent_run, project:, issue:, goal: "create_pr", status: "failed")

    cause = described_class.call(issue).primary

    expect(cause.type).to eq(:technical_recovery)
    expect(cause.action).to eq(:resume_implementation)
    expect(cause.evidence).to include(run_id: run.id)
  end

  # @spec OPERATOR-INBOX-002D
  it "retains an unknown cause visibly" do
    snapshot = described_class.call(issue)

    expect(snapshot.unknown?).to be(true)
    expect(snapshot.primary.label).to eq("Unknown manual-review cause")
    expect(snapshot.action).to be_nil
  end

  # @spec OPERATOR-INBOX-002D
  it "reports unfinished work while retaining the cause-specific action for deduplication" do
    issue.update!(needs_input_questions: [ "Which behavior is required?" ])
    create(:agent_run, project:, issue:, goal: "enhance_issue", status: "queued")

    snapshot = described_class.call(issue)

    expect(snapshot.active_runs).to contain_exactly(hash_including(goal: "enhance_issue", status: "queued"))
    expect(snapshot.action).to eq(:retry_analysis)
  end
end
