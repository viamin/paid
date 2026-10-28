# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  # @spec OPERATOR-INBOX-002D OPERATOR-INBOX-002L ISSUE-REOPEN-REVIEW-005
  it "routes a reopen-review hold by its dedicated persisted provenance" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.for(issue)).to have_attributes(cause: :reopen_review, action: :validate_intent)
  end

  # @spec OPERATOR-INBOX-002D OPERATOR-INBOX-002L
  it "keeps a live dependency waiting instead of retrying enhancement" do
    issue = create(:issue, paid_state: "manual_review")
    dependency = create(:issue, project: issue.project, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    plan = described_class.for(issue)

    expect(plan).to have_attributes(cause: :dependency, action: :wait_for_dependency)
    expect(plan.dependencies).to contain_exactly(have_attributes(depends_on_issue: dependency))
  end

  # @spec OPERATOR-INBOX-002D OPERATOR-INBOX-002L
  it "routes an enhancement stop to the existing enhancement retry" do
    issue = create(:issue, paid_state: "manual_review")
    create(:agent_run, :completed, issue:, project: issue.project, goal: "enhance_issue")

    expect(described_class.for(issue)).to have_attributes(cause: :enhancement, action: :enhance)
  end

  # @spec OPERATOR-INBOX-002D OPERATOR-INBOX-002L
  it "keeps unknown provenance visible without inventing an enhancement retry" do
    issue = create(:issue, paid_state: "manual_review")

    expect(described_class.for(issue)).to have_attributes(cause: :unknown, action: :investigate)
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "records a reason against the reopen revision and refuses active work" do
    actor = create(:user)
    issue = create(:issue, project: create(:project, account: actor.account), paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON, reopened_at: Time.current)

    result = Issues::ValidateReopenReview.call(issue:, actor:, reason: "Evidence must be recollected.")

    expect(result).to be_success
    expect(issue.reload.paid_state).to eq("new")
    expect(actor.account.account_activity_events.last).to have_attributes(action: "issue.reopen_review_validated")
  end
end
