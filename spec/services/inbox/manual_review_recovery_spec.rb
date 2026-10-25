# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:account) { create(:account) }
  let(:project) { create(:project, account:) }

  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
  it "routes the dedicated reopen-review provenance to a recorded decision" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    result = described_class.call(issue:)

    expect(result).to have_attributes(cause: :reopen_review, action: :record_reopen_decision)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps an unresolved dependency as a wait rather than an enhancement retry" do
    dependency = create(:issue, project:, github_state: "open")
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Dependency remains unresolved")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    result = described_class.call(issue:)

    expect(result).to have_attributes(cause: :dependency, action: :wait_for_dependency)
    expect(result.dependencies).to include(dependency)
  end

  # @spec OPERATOR-INBOX-002D
  it "retains an unrecognised hold visibly instead of guessing an enhancement retry" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "A future producer parked this issue")

    expect(described_class.call(issue:)).to have_attributes(cause: :unknown, action: :investigate)
  end
end
