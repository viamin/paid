# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  subject(:recovery) { described_class.new(issue: issue) }

  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project, paid_state: "manual_review") }

  # @spec ISSUE-REOPEN-REVIEW-005 @spec OPERATOR-INBOX-002D
  it "classifies the dedicated reopen-review provenance" do
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(recovery.cause).to have_attributes(key: :reopen_review, action: "resume_implementation")
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps an unresolved dependency as a non-waivable wait" do
    blocker = create(:issue, project: project, github_number: 4321, github_state: "open")
    create(:issue_dependency, issue: issue, depends_on_issue: blocker)

    expect(recovery.cause).to have_attributes(key: :dependency, action: nil)
    expect(recovery.cause.details).to include("#{project.full_name}#4321")
  end

  # @spec ISSUE-ENHANCEMENT-011 @spec OPERATOR-INBOX-002D
  it "routes enhancement provenance to analysis retry" do
    create(:agent_run, :completed, :enhance_issue_goal, project: project, issue: issue)

    expect(recovery.cause).to have_attributes(key: :enhancement, action: "retry_analysis")
  end

  # @spec OPERATOR-INBOX-002D
  it "retains an unclassified cause visibly without offering a run" do
    issue.update!(manual_review_reason: "Legacy producer without structured provenance")

    expect(recovery.cause).to have_attributes(key: :unknown, action: nil)
  end

  # @spec OPERATOR-INBOX-002D
  it "reports unfinished work across goals" do
    run = create(:agent_run, project: project, issue: issue, goal: "create_pr", status: "queued")

    expect(recovery.active_runs).to contain_exactly(run)
  end
end
