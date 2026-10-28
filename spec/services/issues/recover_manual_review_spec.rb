# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::RecoverManualReview do # @spec OPERATOR-INBOX-002L @spec ISSUE-REOPEN-REVIEW-005
  let(:account) { create(:account) }
  let(:actor) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: actor) }
  let(:issue) do
    create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON,
      reopen_reason: "Live validation remains outstanding")
  end

  it "records a revision-bound closure-valid decision" do
    result = described_class.call(issue:, actor:, decision: "closure_valid",
      reason: "The original acceptance evidence remains current.")

    expect(result).to be_success
    expect(issue.reload.paid_state).to eq("completed")
    event = account.account_activity_events.find_by!(action: "issue.reopen_review_resolved")
    expect(event.metadata).to include("decision" => "closure_valid", "revision" => issue.reload.reopen_review_revision)
  end

  it "queues one implementation run and reuses it on a repeated submission" do
    first = described_class.call(issue:, actor:, decision: "remaining_work",
      reason: "Collect the missing live validation artifacts.")
    issue.update!(paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)
    second = described_class.call(issue:, actor:, decision: "remaining_work",
      reason: "Collect the missing live validation artifacts.")

    expect(first).to be_success
    expect(second).to be_success
    expect(second.agent_run).to eq(first.agent_run)
    expect(issue.agent_runs.where(goal: "create_pr").count).to eq(1)
  end

  it "does not let an acknowledgment waive an unresolved dependency" do
    dependency = create(:issue, project:, github_number: 4321, github_state: "open")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    result = described_class.call(issue:, actor:, decision: "remaining_work", reason: "Proceed")

    expect(result.code).to eq(:unresolved_dependency)
    expect(issue.reload).to be_reopen_review_pending
    expect(issue.agent_runs).to be_empty
  end

  it "refuses incompatible unfinished work without clearing the hold" do
    create(:agent_run, project:, issue:, goal: "enhance_issue", status: "queued")

    result = described_class.call(issue:, actor:, decision: "remaining_work", reason: "Proceed")

    expect(result.code).to eq(:incompatible_active_run)
    expect(issue.reload).to be_reopen_review_pending
    expect(issue.agent_runs.count).to eq(1)
  end
end
