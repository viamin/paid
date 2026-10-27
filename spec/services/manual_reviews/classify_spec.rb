# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::Classify do
  # @spec ISSUE-REOPEN-REVIEW-005
  it "classifies the dedicated reopen-review provenance without reading its reason" do
    issue = create(:issue, paid_state: "manual_review", github_state: "open",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON, reopen_reason: "Validation artifacts remain")

    cause = described_class.call(issue: issue)

    expect(cause).to have_attributes(kind: :reopen_review, action: :record_decision)
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "keeps an unresolved dependency ahead of generic enhancement recovery" do
    issue = create(:issue, paid_state: "manual_review", github_state: "open",
      manual_review_reason: Issue::ENHANCEMENT_PARSE_FAILURE_REASON)
    dependency = create(:issue, project: issue.project, github_state: "open")
    create(:issue_dependency, issue: issue, depends_on_issue: dependency)

    cause = described_class.call(issue: issue)

    expect(cause.kind).to eq(:dependency)
    expect(cause.details).to include("#{issue.project.full_name}##{dependency.github_number}")
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "retains an unknown cause visibly instead of treating it as enhancement work" do
    issue = create(:issue, paid_state: "manual_review", manual_review_reason: "legacy producer state")

    expect(described_class.call(issue: issue)).to have_attributes(kind: :unknown, action: :inspect)
  end
end
