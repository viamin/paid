# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ManualReviewRecovery do
  let(:project) { create(:project) }

  def review_issue(**attributes)
    create(:issue, { project:, paid_state: "manual_review", github_state: "open" }.merge(attributes))
  end

  # @spec OPERATOR-INBOX-002D
  it "retains an unknown stop visibly when no durable producer evidence exists" do
    recovery = described_class.call(issue: review_issue(manual_review_reason: "operator supplied note"))

    expect(recovery).to be_unknown
    expect(recovery.action).to eq(:investigate)
  end

  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-001
  it "prioritizes the dedicated reopen-review provenance over historical enhancement runs" do
    issue = review_issue(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)
    create(:agent_run, project:, issue:, goal: "enhance_issue", status: "completed")

    expect(described_class.call(issue:)).to be_reopen
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps a real unresolved dependency held even when enhancement history exists" do
    blocker = create(:issue, project:, github_state: "open")
    issue = review_issue(manual_review_reason: "Waiting for dependency")
    create(:issue_dependency, issue:, depends_on_issue: blocker)
    create(:agent_run, project:, issue:, goal: "enhance_issue", status: "completed")

    recovery = described_class.call(issue:)

    expect(recovery).to be_dependency
    expect(recovery.blockers).to eq([ { label: "##{blocker.github_number}", url: blocker.github_url } ])
  end

  # @spec OPERATOR-INBOX-002D EAGER-QUEUE-013
  it "routes only a scanner-confirmed recurrence to remediation authorization" do
    issue = review_issue(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    recovery = described_class.call(issue:)

    expect(recovery).to be_scanner
    expect(recovery.action).to eq(:authorize_remediation)
  end

  # @spec OPERATOR-INBOX-002D
  it "requires reconciliation instead of creating another run while work is queued" do
    issue = review_issue(manual_review_reason: "Structured output failed validation.")
    active_run = create(:agent_run, project:, issue:, goal: "create_pr", status: "queued")

    recovery = described_class.call(issue:)

    expect(recovery).to be_active_work
    expect(recovery.blockers).to eq([
      { label: "create pr run ##{active_run.id} (queued)", url: "/projects/#{project.id}/agent_runs/#{active_run.id}" }
    ])
  end
end
