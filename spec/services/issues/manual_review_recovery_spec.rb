# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ManualReviewRecovery do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:, paid_state: "manual_review") }

  # @spec ISSUE-REOPEN-REVIEW-005 @spec OPERATOR-INBOX-002D
  it "routes the dedicated reopen hold to a revision-bound evidence run" do
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    recovery = described_class.call(issue: issue)

    expect(recovery).to have_attributes(cause: :reopen_review, goal: "analyze_issue", revision: issue.github_updated_at.iso8601)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps a real dependency hold non-actionable and identifies its owner" do
    blocker = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    recovery = described_class.call(issue: issue)

    expect(recovery).to have_attributes(cause: :dependency, dependency: blocker, goal: nil)
  end

  # @spec OPERATOR-INBOX-002D
  it "does not create a second run while queued work needs reconciliation" do
    create(:agent_run, project:, issue:, status: "queued", goal: "create_pr")

    recovery = described_class.call(issue: issue)

    expect(recovery).to have_attributes(cause: :unknown, active_run: issue.agent_runs.first)
    expect(recovery).not_to be_actionable
  end

  # @spec OPERATOR-INBOX-002D
  it "retains an otherwise unprovenanced hold as unknown" do
    issue.update!(manual_review_reason: "A historic operator hold")

    expect(described_class.call(issue: issue)).to have_attributes(cause: :unknown, goal: nil)
  end
end
