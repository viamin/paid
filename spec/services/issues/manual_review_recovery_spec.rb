# frozen_string_literal: true

require "rails_helper"

RSpec.describe Issues::ManualReviewRecovery do
  let(:account) { create(:account) }
  let(:actor) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: actor) }
  let(:issue) { create(:issue, project:, paid_state: "manual_review") }

  def recover(action:, reason: nil, decision: nil)
    described_class.call(issue:, actor:, action:, reason:, decision:)
  end

  # @spec MANUAL-REVIEW-RECOVERY-002 @spec MANUAL-REVIEW-RECOVERY-008
  it "records one revision-bound reopen decision across a double submit" do
    issue.require_reopen_review!

    first = recover(action: "record_intent_validation", decision: "intent_valid", reason: "The reported scope remains open.")
    issue.update!(paid_state: "manual_review", manual_review_reason: Issue::REOPEN_REVIEW_REQUIRED_REASON)
    second = recover(action: "record_intent_validation", decision: "intent_valid", reason: "The reported scope remains open.")

    expect(first).to be_success
    expect(second).to be_success
    expect(ManualReviewDecision.where(issue:)).to have_attributes(count: 1)
  end

  # @spec MANUAL-REVIEW-RECOVERY-003
  it "does not let a dependency acknowledgement clear an unresolved dependency" do
    issue.update!(manual_review_cause: "dependency_wait")
    blocker = create(:issue, project:, github_state: "open")
    create(:issue_dependency, issue:, depends_on_issue: blocker)

    result = recover(action: "reevaluate_dependency")

    expect(result.code).to eq(:dependency_unresolved)
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  # @spec MANUAL-REVIEW-RECOVERY-006 @spec MANUAL-REVIEW-RECOVERY-008
  it "reuses an already queued compatible enhancement run" do
    issue.update!(manual_review_cause: "enhancement")
    run = create(:agent_run, :queued, project:, issue:, goal: "enhance_issue")

    result = recover(action: "retry_enhancement")

    expect(result).to be_success
    expect(result.agent_run).to eq(run)
    expect(issue.agent_runs.count).to eq(1)
    expect(issue.reload.paid_state).to eq("manual_review")
  end

  # @spec MANUAL-REVIEW-RECOVERY-006
  it "refuses a recovery while incompatible automatic work remains queued" do
    issue.update!(manual_review_cause: "enhancement")
    run = create(:agent_run, :queued, project:, issue:, goal: "create_pr", trigger_type: "automatic")

    result = recover(action: "retry_enhancement")

    expect(result.code).to eq(:conflicting_run)
    expect(result.message).to include("##{run.id}")
    expect(issue.reload.paid_state).to eq("manual_review")
  end
end
