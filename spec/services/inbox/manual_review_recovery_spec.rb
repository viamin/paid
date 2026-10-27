# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  # @spec ISSUE-REOPEN-REVIEW-005
  it "classifies dedicated reopen provenance without treating it as an enhancement retry" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    recovery = described_class.for(issue:)

    expect(recovery.cause).to eq(:reopen_review)
    expect(recovery.requires_decision?).to be(true)
    expect(recovery.action).to eq(:record_reopen_decision)
  end

  # @spec ISSUE-REOPEN-REVIEW-006
  it "keeps an unresolved dependency as a wait with its owner" do
    issue = create(:issue, project:, paid_state: "manual_review")
    dependency = create(:issue, project:, github_state: "open", title: "Ship prerequisite")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    recovery = described_class.for(issue:)

    expect(recovery.cause).to eq(:dependency)
    expect(recovery.action).to eq(:wait_for_dependency)
    expect(recovery.dependencies).to contain_exactly(dependency)
  end

  # @spec ISSUE-REOPEN-REVIEW-006
  it "does not guess an enhancement action for unknown provenance" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Operator supplied hold")

    recovery = described_class.for(issue:)

    expect(recovery.cause).to eq(:unknown)
    expect(recovery.action).to eq(:none)
  end
end
