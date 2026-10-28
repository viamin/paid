# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ManualReviewRecovery do
  let(:account) { create(:account) }
  let(:project) { create(:project, account: account) }
  let(:issue) { create(:issue, project: project, paid_state: "manual_review") }

  it "recognizes the dedicated reopen-review provenance" do # @spec ISSUE-REOPEN-REVIEW-005
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue).cause).to eq(:reopen_review)
  end

  it "keeps an unresolved dependency distinct from enhancement recovery" do # @spec OPERATOR-INBOX-002L
    dependency = create(:issue, project: project, github_number: 4321, github_state: "open")
    create(:issue_dependency, issue: issue, depends_on_issue: dependency)

    recovery = described_class.call(issue)

    expect(recovery.cause).to eq(:dependency_wait)
    expect(recovery.dependency_numbers).to contain_exactly(4321)
    expect(recovery.resumable?).to be(false)
  end

  it "retains unknown manual-review provenance visibly" do # @spec OPERATOR-INBOX-002L
    issue.update!(manual_review_reason: "An operator supplied an unclassified hold.")

    recovery = described_class.call(issue)

    expect(recovery.cause).to eq(:unknown)
    expect(recovery.label).to eq("Unknown manual-review cause")
  end

  it "reports queued work instead of authorizing a second resume" do # @spec OPERATOR-INBOX-002L
    create(:agent_run, project: project, issue: issue, goal: "create_pr", status: "queued")

    recovery = described_class.call(issue)

    expect(recovery.active_run).to be_present
    expect(recovery.resumable?).to be(false)
  end
end
