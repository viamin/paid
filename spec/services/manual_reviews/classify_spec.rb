# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::Classify do
  let(:project) { create(:project) }

  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
  it "prioritizes the dedicated reopen-review provenance" do
    issue = create(:issue, project: project, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue: issue).cause).to eq(:reopen_review)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps an unresolved recorded dependency distinct from enhancement recovery" do
    issue = create(:issue, project: project, paid_state: "manual_review", manual_review_reason: "Waiting")
    blocker = create(:issue, project: project, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue: issue, depends_on_issue: blocker)

    result = described_class.call(issue: issue)

    expect(result).to be_dependency
    expect(result.blockers.map(&:code)).to include(:unmet_prerequisites)
  end

  # @spec OPERATOR-INBOX-002D
  it "retains an unknown stop rather than guessing an enhancement retry" do
    issue = create(:issue, project: project, paid_state: "manual_review", manual_review_reason: "Operator investigation required")

    expect(described_class.call(issue: issue).cause).to eq(:unknown)
  end

  # @spec OPERATOR-INBOX-002D
  it "routes scanner-confirmed recurrence from its verification attempt" do
    issue = create(:issue, project: project, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 42,
      paid_state: "manual_review", manual_review_reason: "Scanner recurrence")
    create(:code_scanning_remediation_attempt, issue: issue, status: "verification_failed")

    expect(described_class.call(issue: issue).cause).to eq(:scanner_recurrence)
  end
end
