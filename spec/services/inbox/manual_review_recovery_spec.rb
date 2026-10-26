# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:issue) do
    create(:issue, paid_state: "manual_review", manual_review_reason: "A legacy stop.")
  end

  # @spec OPERATOR-INBOX-002K
  it "recognizes the reopen-review sentinel without interpreting its text" do
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    recovery = described_class.call(issue: issue)

    expect(recovery.cause).to eq(:reopen_review)
    expect(recovery.requires_decision?).to be(true)
    expect(recovery.action).to eq(:enhance)
  end

  # @spec OPERATOR-INBOX-002K
  it "keeps a real unresolved dependency held ahead of generic enhancement" do
    dependency = create(:issue, project: issue.project, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: issue, depends_on_issue: dependency)

    recovery = described_class.call(issue: issue)

    expect(recovery.cause).to eq(:dependency)
    expect(recovery.action).to eq(:wait_for_dependency)
    expect(recovery.dependencies).to eq([ dependency ])
  end

  # @spec OPERATOR-INBOX-002K
  it "preserves an unknown cause instead of guessing from free text" do
    recovery = described_class.call(issue: issue)

    expect(recovery.cause).to eq(:unknown)
    expect(recovery.action).to eq(:none)
  end
end
