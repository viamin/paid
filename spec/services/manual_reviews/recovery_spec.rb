# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::Recovery do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project: project, paid_state: "manual_review") }

  # @spec ISSUE-REOPEN-REVIEW-005 OPERATOR-INBOX-002D
  it "classifies the dedicated reopen marker without relying on reason text" do
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.for(issue)).to have_attributes(kind: :reopen_review, action: :record_reopen_review)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps a real unresolved dependency distinct from enhancement recovery" do
    dependency = create(:issue, project: project, github_number: 4321)
    create(:issue_dependency, issue: issue, depends_on_issue: dependency)

    recovery = described_class.for(issue)

    expect(recovery).to have_attributes(kind: :dependency, action: :wait_for_dependency)
    expect(recovery.blocking_records).to include(dependency)
  end

  # @spec OPERATOR-INBOX-002D
  it "retains an unknown manual-review reason visibly" do
    issue.update!(manual_review_reason: "A producer not yet understood parked this issue.")

    expect(described_class.for(issue)).to have_attributes(kind: :unknown, action: :investigate)
  end
end
