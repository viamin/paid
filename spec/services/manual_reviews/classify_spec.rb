# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::Classify do
  # @spec OPERATOR-INBOX-002K
  it "classifies reopen review from its dedicated provenance" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue: issue)).to have_attributes(cause: :reopen_review, action: :record_decision)
  end

  # @spec OPERATOR-INBOX-002K
  it "keeps a real unresolved dependency distinct from enhancement recovery" do
    issue = create(:issue, paid_state: "manual_review")
    dependency = create(:issue, project: issue.project, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: issue, depends_on_issue: dependency)

    recovery = described_class.call(issue: issue)
    expect(recovery).to have_attributes(cause: :dependency, action: :wait_for_dependency)
    expect(recovery.blockers).to eq([ dependency ])
  end

  # @spec OPERATOR-INBOX-002K
  it "retains unknown provenance instead of guessing from free-form reason text" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: "Please enhance this")

    expect(described_class.call(issue: issue)).to have_attributes(cause: :unknown, action: :investigate)
  end
end
