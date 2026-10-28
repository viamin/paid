# frozen_string_literal: true

require "rails_helper"

# @spec OPERATOR-INBOX-002I @spec ISSUE-REOPEN-REVIEW-005
RSpec.describe Inbox::ManualReviewCause do
  let(:project) { create(:project) }

  it "classifies the dedicated reopen-review provenance" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue)).to be_reopen_review
  end

  it "classifies a real unresolved dependency without trusting reason text" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Enhancement failed")
    blocker = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    cause = described_class.call(issue)

    expect(cause).to be_dependency
    expect(cause.dependencies).to contain_exactly(blocker)
  end

  it "classifies enhancement provenance with and without questions" do
    with_questions = create(:issue, project:, paid_state: "manual_review", needs_input_questions: [ "Which scope?" ])
    without_questions = create(:issue, project:, paid_state: "manual_review")
    create(:agent_run, project:, issue: without_questions, goal: "enhance_issue", status: "failed")

    expect(described_class.call(with_questions)).to be_enhancement
    expect(described_class.call(without_questions)).to be_enhancement
  end

  it "retains an unproven cause as unknown" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Something novel happened")

    expect(described_class.call(issue)).to be_unknown
  end

  it "classifies scanner recurrence from the persisted remediation attempt" do
    issue = create(:issue, project:, source: Issue::SYNTHETIC_CODE_SCANNING_SOURCE,
      paid_state: "manual_review")
    create(:code_scanning_remediation_attempt, issue:, status: "verification_failed")

    expect(described_class.call(issue)).to be_scanner
  end

  it "classifies technical recovery from partial-completion evidence" do
    issue = create(:issue, project:, paid_state: "manual_review", partial_completion_at: Time.current)

    expect(described_class.call(issue)).to be_technical
  end

  it "keeps a simultaneous dependency hold authoritative" do
    issue = create(:issue, project:, paid_state: "manual_review", needs_input_questions: [ "Which scope?" ])
    blocker = create(:issue, project:, github_state: "open", paid_state: "new")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    expect(described_class.call(issue)).to be_dependency
  end

  it "reports queued work alongside the cause" do
    issue = create(:issue, project:, paid_state: "manual_review", needs_input_questions: [ "Which scope?" ])
    run = create(:agent_run, project:, issue:, goal: "enhance_issue", status: "queued")

    expect(described_class.call(issue).active_runs).to contain_exactly(run)
  end
end
