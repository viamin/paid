# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  # @spec OPERATOR-INBOX-002L
  it "classifies the explicit reopen-review marker before generic enhancement provenance" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    recovery = described_class.call(issue)

    expect(recovery.kind).to eq(:reopen_review)
    expect(recovery.action).to eq(:record_reopen_decision)
  end

  # @spec OPERATOR-INBOX-002L
  it "keeps a real open dependency as a dependency hold" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: "Enhancement stopped")
    dependency = create(:issue, project: issue.project, github_state: "open")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    recovery = described_class.call(issue)

    expect(recovery.kind).to eq(:dependency)
    expect(recovery.dependencies).to contain_exactly(have_attributes(depends_on_issue: dependency))
  end

  # @spec OPERATOR-INBOX-002L
  it "retains an unknown cause instead of claiming it is safe to retry" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: "A durable hold from another producer")

    recovery = described_class.call(issue)

    expect(recovery.kind).to eq(:unknown)
    expect(recovery.action).to eq(:investigate)
  end
end
