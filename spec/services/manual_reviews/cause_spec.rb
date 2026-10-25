# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::Cause do
  let(:project) { create(:project) }

  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
  it "uses the dedicated reopen-review provenance ahead of all other signals" do
    issue = create(:issue, project: project, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue: issue).kind).to eq(:reopen_review)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps a real unresolved dependency distinct from enhancement recovery" do
    dependency = create(:issue, project: project, github_state: "open")
    issue = create(:issue, project: project, paid_state: "manual_review")
    create(:issue_dependency, issue: issue, depends_on_issue: dependency)

    result = described_class.call(issue: issue)

    expect(result.kind).to eq(:dependency)
    expect(result.blocking_issues).to contain_exactly(dependency)
  end

  # @spec OPERATOR-INBOX-002D
  it "uses scanner-attempt provenance for a confirmed recurrence" do
    issue = create(:issue, project: project, paid_state: "manual_review")
    attempt = create(:code_scanning_remediation_attempt, issue: issue, status: "verification_failed")

    result = described_class.call(issue: issue)

    expect(result.kind).to eq(:scanner_recurrence)
    expect(result.scanner_attempt).to eq(attempt)
  end

  # @spec OPERATOR-INBOX-002D ISSUE-ENHANCEMENT-011
  it "retains enhancement recovery when a parked question exists" do
    issue = create(:issue, project: project, paid_state: "manual_review", needs_input_questions: [ "Which scope?" ])

    expect(described_class.call(issue: issue).kind).to eq(:enhancement)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps an unannotated legacy hold visibly unknown" do
    issue = create(:issue, project: project, paid_state: "manual_review", manual_review_reason: nil)

    expect(described_class.call(issue: issue).kind).to eq(:unknown)
  end
end
