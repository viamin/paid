# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ManualReviewRecovery do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:, paid_state: "manual_review") }

  # @spec OPERATOR-INBOX-002K ISSUE-REOPEN-REVIEW-005
  it "routes a pending reopen review to a decision rather than enhancement" do
    issue.require_reopen_review!

    result = described_class.call(issue: issue)

    expect(result).to be_reopen_review
    expect(result.action).to eq(:record_decision)
  end

  # @spec OPERATOR-INBOX-002K
  it "keeps a real dependency waiting instead of offering enhancement" do
    dependency = create(:issue, project:, github_number: 4321, github_state: "open")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    result = described_class.call(issue: issue)

    expect(result).to be_dependency
    expect(result.message).to include("#4321")
  end

  # @spec OPERATOR-INBOX-002K
  it "routes scanner recurrence to scanner evidence" do
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    result = described_class.call(issue: issue)

    expect(result).to be_scanner_recurrence
    expect(result.action).to eq(:review_scanner_evidence)
  end

  # @spec OPERATOR-INBOX-002K
  it "preserves enhancement retry for established enhancement provenance" do
    create(:agent_run, project:, issue:, goal: "enhance_issue")

    expect(described_class.call(issue: issue)).to be_enhancement
  end

  # @spec OPERATOR-INBOX-002K
  it "keeps unknown provenance visible without a clearing action" do
    result = described_class.call(issue: issue)

    expect(result).to be_unknown
    expect(result.action).to eq(:none)
  end
end

RSpec.describe Issues::ResolveReopenReview do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }
  let(:issue) { create(:issue, project:, paid_state: "manual_review") }

  # @spec ISSUE-REOPEN-REVIEW-005
  it "records an authorized decision against the reviewed revision without queueing work" do
    issue.require_reopen_review!

    expect {
      result = described_class.call(issue:, actor: user, reason: "The migration evidence is still missing.",
        revision: issue.github_updated_at.iso8601(6))
      expect(result).to be_success
    }.not_to change(AgentRun, :count)

    expect(issue.reload).to have_attributes(
      paid_state: "new", reopen_reviewed_by: user, reopen_review_decision: "intent_validated",
      reopen_review_reason: "The migration evidence is still missing.", reopen_review_revision: issue.github_updated_at
    )
    expect(account.account_activity_events.where(action: "issue.reopen_review_resolved")).to exist
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "refuses a stale revision without releasing the hold" do
    issue.require_reopen_review!

    result = described_class.call(issue:, actor: user, reason: "Reviewed.", revision: 1.minute.ago.iso8601(6))

    expect(result.code).to eq(:stale_revision)
    expect(issue.reload).to be_reopen_review_pending
  end
end
