# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::Recovery do
  let(:project) { create(:project) }

  # @spec ISSUE-REOPEN-REVIEW-005 @spec OPERATOR-INBOX-002J
  it "uses the dedicated reopen-review provenance before legacy stop text" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue: issue)).to have_attributes(
      cause: :reopen_review, action: :record_reopen_review
    )
  end

  # @spec OPERATOR-INBOX-002J
  it "keeps a real unresolved dependency as a wait with its owner issue" do
    dependency = create(:issue, project:, github_state: "open", github_number: 4321)
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Blocked")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    recovery = described_class.call(issue: issue)

    expect(recovery).to have_attributes(cause: :dependency_wait, action: :wait_for_dependency)
    expect(recovery.blocking_issues).to eq([ dependency ])
  end

  # @spec OPERATOR-INBOX-002J
  it "routes a scanner recurrence to its evidence review" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Stopped")
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    expect(described_class.call(issue: issue)).to have_attributes(
      cause: :scanner_recurrence, action: :review_scanner_evidence
    )
  end

  # @spec OPERATOR-INBOX-002J
  it "keeps missing provenance visibly unknown" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: nil)

    expect(described_class.call(issue: issue)).to have_attributes(cause: :unknown, action: :investigate)
  end
end
