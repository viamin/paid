# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ManualReviewRecovery do # @spec ISSUE-REOPEN-REVIEW-005 OPERATOR-INBOX-002L
  let(:account) { create(:account) }
  let(:actor) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: actor) }
  let(:issue) { create(:issue, project:, paid_state: "manual_review") }

  it "records a revision-bound reopen decision and queues implementation" do
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    result = described_class.call(issue:, actor:, reason: "The reopened acceptance gap needs implementation.",
      review_revision: issue.manual_review_started_at)

    expect(result.success?).to be(true)
    expect(result.agent_run).to have_attributes(goal: "create_pr", trigger_type: "manual", status: "queued")
    expect(issue.reload.paid_state).to eq("in_progress")
    expect(account.account_activity_events.where(action: "issue.reopen_review_resolved").last.metadata).to include(
      "reason" => "The reopened acceptance gap needs implementation."
    )
  end

  it "does not waive an unresolved dependency" do
    blocker = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue:, depends_on_issue: blocker)
    issue.update!(manual_review_reason: "Waiting for dependency ##{blocker.github_number}.")

    result = described_class.call(issue:, actor:)

    expect(result.code).to eq(:dependency_pending)
    expect(result.blockers).to contain_exactly(blocker)
    expect(issue.agent_runs).to be_empty
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  it "reuses compatible queued recovery work and refuses incompatible work" do
    issue.update!(manual_review_reason: "Structured output was invalid.")
    queued = create(:agent_run, :queued, project:, issue:, goal: "enhance_issue")

    result = described_class.call(issue:, actor:)
    expect(result.success?).to be(true)
    expect(result.agent_run).to eq(queued)
    expect(issue.reload.paid_state).to eq("manual_review")

    queued.update!(goal: "create_pr")
    result = described_class.call(issue:, actor:)
    expect(result.code).to eq(:incompatible_active_run)
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  it "retains unknown provenance without inventing a run" do
    issue.update!(manual_review_reason: "A legacy producer parked this item.")

    result = described_class.call(issue:, actor:)

    expect(result.code).to eq(:unknown_cause)
    expect(issue.agent_runs).to be_empty
  end
end
