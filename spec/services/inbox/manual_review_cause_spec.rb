# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewCause do # @spec OPERATOR-INBOX-002L
  let(:project) { create(:project) }

  it "classifies dedicated reopen-review provenance" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue).kind).to eq(:reopen_review)
  end

  it "gives a real unresolved dependency precedence over retry actions" do
    dependency = create(:issue, project:, github_number: 42, github_state: "open")
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: "Enhancement failed")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    cause = described_class.call(issue)

    expect(cause.kind).to eq(:dependency)
    expect(cause.dependencies).to contain_exactly(dependency)
  end

  it "classifies enhancement questions and scanner recurrence" do
    enhancement = create(:issue, project:, paid_state: "manual_review",
      needs_input_questions: [ "Which scope?" ])
    scanner = create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      paid_state: "manual_review")

    expect(described_class.call(enhancement).kind).to eq(:enhancement)
    expect(described_class.call(scanner).kind).to eq(:scanner_recurrence)
  end

  it "retains unknown causes visibly" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: "Operator review required")

    expect(described_class.call(issue).kind).to eq(:unknown)
  end
end
