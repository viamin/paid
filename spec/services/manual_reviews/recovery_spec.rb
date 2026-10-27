# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::Recovery do
  let(:project) { create(:project) }

  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
  it "classifies reopen review from its dedicated durable marker" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    result = described_class.call(issue:)

    expect(result).to have_attributes(cause: :reopen, action: :validate_intent)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps an unrecognized manual-review reason visibly unknown" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Operator supplied context")

    expect(described_class.call(issue:).cause).to eq(:unknown)
  end

  # @spec OPERATOR-INBOX-002D
  it "does not mistake an unresolved dependency for an enhancement retry" do
    blocker = create(:issue, project:, github_state: "open")
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "round limit")
    issue.issue_dependencies.create!(depends_on_issue: blocker)

    result = described_class.call(issue:)

    expect(result).to have_attributes(cause: :dependency, action: :wait_for_dependency)
    expect(result.blockers).to include(blocker)
  end
end
