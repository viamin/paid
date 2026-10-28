# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: actor) }

  # @spec OPERATOR-INBOX-002L ISSUE-REOPEN-REVIEW-005
  it "classifies a reopen hold from its dedicated provenance and records one revision-bound decision" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue:)).to have_attributes(cause: :reopen_review, action: :record_decision)

    result = described_class.resolve(
      issue:,
      actor:,
      revision: issue.github_updated_at.iso8601,
      decision: "resume_implementation",
      reason: "The reopened report still needs the missing validation artifacts."
    )

    expect(result).to be_success
    expect(AccountActivityEvent.where(action: "issue.reopen_review_decided", subject: issue).last.metadata).to include(
      "revision" => issue.github_updated_at.iso8601,
      "decision" => "resume_implementation"
    )
    expect(described_class.resolve(issue:, actor:, revision: issue.github_updated_at.iso8601,
      decision: "resume_implementation", reason: "duplicate")).to have_attributes(code: :already_decided)
  end

  # @spec OPERATOR-INBOX-002L
  it "keeps an unresolved dependency visible and refuses to let an acknowledgement waive it" do
    blocker = create(:issue, project:, github_state: "open", paid_state: "new")
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    expect(described_class.call(issue:)).to have_attributes(cause: :dependency, action: :wait_for_dependency)
    result = described_class.resolve(issue:, actor:, revision: issue.github_updated_at.iso8601,
      decision: "resume_implementation", reason: "acknowledged")

    expect(result).to have_attributes(code: :dependency_unresolved)
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  # @spec OPERATOR-INBOX-002L
  it "routes enhancement holds to enhancement retry, scanner recurrence to remediation, and unknown provenance to no destructive action" do
    enhancement = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "transport failed")
    create(:agent_run, :failed, project:, issue: enhancement, goal: "enhance_issue")
    scanner = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "unexplained")
    attempt = create(:code_scanning_remediation_attempt, issue: scanner, status: "verification_failed")
    unknown = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "An operator needs to investigate.")

    expect(described_class.call(issue: enhancement)).to have_attributes(cause: :enhancement, continuation_goal: "enhance_issue")
    expect(described_class.call(issue: scanner)).to have_attributes(cause: :scanner_recurrence, continuation_goal: "create_pr")
    expect(described_class.call(issue: unknown)).to have_attributes(cause: :unknown, action: :investigate)
    expect(attempt).to be_present
  end

  # @spec OPERATOR-INBOX-002L
  it "does not offer a second run while any work for the issue is queued or running" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "transport failed")
    active = create(:agent_run, project:, issue:, goal: "create_pr", status: "queued")

    recovery = described_class.call(issue:)

    expect(recovery).to have_attributes(action: :reconcile_active_run, active_run: active)
  end
end
