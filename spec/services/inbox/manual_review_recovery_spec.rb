# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:project) { create(:project) }

  it "classifies the dedicated reopen-review provenance" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue:)).to have_attributes(cause: :reopen_review, action: :record_decision)
  end

  it "keeps an unresolved dependency waiting and names its owner" do
    blocker = create(:issue, project:, github_number: 4321, github_state: "open")
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Waiting")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    recovery = described_class.call(issue:)
    expect(recovery).to have_attributes(cause: :dependency, action: :wait)
    expect(recovery.blockers.map(&:github_number)).to eq([ 4321 ])
  end

  it "classifies a scanner-confirmed recurrence from durable scanner evidence" do
    issue = create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      github_issue_id: Issue::SYNTHETIC_CODE_SCANNING_ID_OFFSET + 7,
      paid_state: "manual_review", manual_review_reason: "anything")
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    expect(described_class.call(issue:)).to have_attributes(cause: :scanner_recurrence, action: :resume_implementation)
  end

  it "retains unknown provenance visibly rather than guessing" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Something novel happened")

    expect(described_class.call(issue:)).to have_attributes(cause: :unknown, action: :none)
  end
end
