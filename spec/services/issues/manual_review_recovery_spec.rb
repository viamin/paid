# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ManualReviewRecovery do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project, paid_state: "manual_review") }

  # @spec OPERATOR-INBOX-002L @spec ISSUE-REOPEN-REVIEW-005
  it "classifies the dedicated reopen-review provenance without parsing its reason" do
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    result = described_class.call(issue: issue)

    expect(result.cause).to eq(:reopen)
    expect(result.continuation_goal).to eq("create_pr")
  end

  # @spec OPERATOR-INBOX-002L
  it "keeps an unresolved dependency ahead of any generic enhancement retry" do
    blocker = create(:issue, project: project, github_state: "open")
    create(:issue_dependency, issue: issue, depends_on_issue: blocker)
    create(:agent_run, :failed, project: project, issue: issue, goal: "enhance_issue")

    result = described_class.call(issue: issue)

    expect(result.cause).to eq(:dependency)
    expect(result).to be_blocked_by_dependency
    expect(result).not_to be_continuation
  end

  # @spec OPERATOR-INBOX-002L
  it "reuses an active run instead of authorizing a second continuation" do
    run = create(:agent_run, :queued, project: project, issue: issue, goal: "create_pr")

    result = described_class.call(issue: issue)

    expect(result.active_run).to eq(run)
    expect(result).to be_blocked_by_active_run
    expect(result).not_to be_continuation
  end

  # @spec OPERATOR-INBOX-002L
  it "retains an unknown manual-review cause without guessing an enhancement action" do
    result = described_class.call(issue: issue)

    expect(result.cause).to eq(:unknown)
    expect(result.continuation_goal).to be_nil
  end
end
