# frozen_string_literal: true

require "rails_helper"

RSpec.describe ManualReviews::Recovery do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: user) }

  # @spec ISSUE-REOPEN-REVIEW-005
  it "requires and records a revision-bound reopen validation before enhancement recovery" do
    issue = create(:issue, project:, paid_state: "manual_review",
      manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)
    recovery = described_class.new(issue:)

    expect(recovery.call.action).to eq(:record_decision)

    expect {
      recovery.record_reopen_validation!(actor: user, reason: "Live validation evidence is still required.",
        revision: issue.github_updated_at.iso8601)
    }.to change(DecisionRecord, :count).by(1)

    expect(recovery.call.action).to eq(:resume_enhancement)
    expect(issue.decision_records.last).to have_attributes(status: "active", tags: [ "reopen_review_validation" ])
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "does not let an acknowledgement waive a real dependency" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Dependency unresolved")
    dependency = create(:issue, project:, github_state: "open")
    create(:issue_dependency, issue:, depends_on_issue: dependency)

    result = described_class.call(issue:)

    expect(result).to have_attributes(key: :dependency, action: :wait)
    expect(result.message).to include("##{dependency.github_number}")
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "keeps unknown provenance visible without an unsafe clearing action" do
    issue = create(:issue, project:, paid_state: "manual_review", manual_review_reason: "Legacy hold")

    expect(described_class.call(issue:)).to have_attributes(key: :unknown, action: :none)
  end

  # @spec ISSUE-REOPEN-REVIEW-005
  it "reports queued work before a continuation can be created" do
    issue = create(:issue, project:, paid_state: "manual_review", needs_input_questions: [ "What changed?" ])
    run = create(:agent_run, project:, issue:, goal: "create_pr", status: "queued")

    expect(described_class.call(issue:).blocking_runs).to contain_exactly(run)
  end
end
