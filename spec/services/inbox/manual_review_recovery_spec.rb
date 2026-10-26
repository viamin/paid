# frozen_string_literal: true

require "rails_helper"

RSpec.describe Inbox::ManualReviewRecovery do
  let(:project) { create(:project) }

  # @spec OPERATOR-INBOX-002D ISSUE-REOPEN-REVIEW-005
  it "classifies reopen review from its dedicated durable provenance" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)

    expect(described_class.call(issue:)).to have_attributes(cause: :reopen_review, action: :validate_intent)
  end

  # @spec OPERATOR-INBOX-002D
  it "keeps an unresolved declared dependency ahead of generic enhancement recovery" do
    blocker = create(:issue, project:, github_state: "open", paid_state: "new")
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Waiting", needs_input_questions: [ "Question?" ])
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    expect(described_class.call(issue:)).to have_attributes(cause: :dependency_wait, action: :wait_for_dependency, dependency: blocker)
  end

  # @spec OPERATOR-INBOX-002D
  it "reconciles an active run before attempting any new recovery" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Round limit")
    run = create(:agent_run, project:, issue:, status: "queued", goal: "enhance_issue")

    expect(described_class.call(issue:)).to have_attributes(cause: :active_work, action: :reconcile, active_run: run)
  end

  # @spec OPERATOR-INBOX-002D
  it "retains an unknown stop as explicitly investigable" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Legacy operator hold")

    expect(described_class.call(issue:)).to have_attributes(cause: :unknown, action: :investigate)
  end
end
