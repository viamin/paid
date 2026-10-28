# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::Recovery do
  let(:project) { create(:project) }
  let(:issue) { create(:issue, project:, paid_state: "manual_review") }

  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-001
  it "identifies the reopen gate from its dedicated provenance" do
    issue.update!(manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    recovery = described_class.call(issue:)

    expect(recovery).to have_attributes(cause: :reopen_review, action: :record_reopen_decision)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps a real unresolved dependency out of enhancement recovery" do
    dependency = create(:issue, project:, github_number: 4321, github_state: "open", paid_state: "new")
    issue.issue_dependencies.create!(depends_on_issue: dependency)

    recovery = described_class.call(issue:)

    expect(recovery).to have_attributes(cause: :dependency_wait, action: :wait_for_dependency)
    expect(recovery.dependencies).to contain_exactly(dependency)
  end

  # @spec OPERATOR-INBOX-002D EAGER-QUEUE-014
  it "routes scanner recurrence from its persisted verification attempt" do
    issue.update!(source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE)
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    recovery = described_class.call(issue:)

    expect(recovery).to have_attributes(cause: :scanner_recurrence, action: :authorize_remediation)
  end

  # @spec OPERATOR-INBOX-002D ISSUE-ENHANCEMENT-011
  it "permits the existing enhancement retry only for preserved questions" do
    issue.update!(needs_input_questions: [ "Which behavior should ship?" ])

    expect(described_class.call(issue:)).to have_attributes(cause: :enhancement_questions, action: :retry_enhancement)
  end

  # @spec OPERATOR-INBOX-002D ISSUE-ENHANCEMENT-002
  it "routes a failed enhancement run to the existing analysis retry" do
    create(:agent_run, :failed, project:, issue:, goal: "enhance_issue")

    expect(described_class.call(issue:)).to have_attributes(cause: :enhancement_failure, action: :retry_enhancement)
  end

  # @spec OPERATOR-INBOX-002D
  it "retains unrecognized provenance visibly and does not guess a retry" do
    issue.update!(manual_review_reason: "A future producer parked this issue.")

    expect(described_class.call(issue:)).to have_attributes(cause: :unknown, action: :inspect)
  end
end
