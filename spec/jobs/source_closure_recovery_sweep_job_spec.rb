# frozen_string_literal: true

require "rails_helper"

RSpec.describe SourceClosureRecoverySweepJob do # @spec PARTIAL-CLOSEOUT-043
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: owner, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }
  let(:agent_run) do
    create(:agent_run, :paused, project: project, issue: issue, goal: "create_pr",
      branch_name: "agent/issue-7", result_commit_sha: "abc123def456")
  end

  def park(next_retry_at:)
    error = Llm::AnalyzePartialCloseout::AssessmentFailure.new("Partial closeout assessment timed out waiting for the runner.",
      category: "timeout")
    PartialCloseouts::SourceClosureRecoveryState.record_attempt(agent_run, error: error,
      branch: agent_run.branch_name, commit_sha: agent_run.result_commit_sha)
    agent_run.update!(reconciliation: agent_run.reconciliation.merge(
      "source_closure_recovery" => PartialCloseouts::SourceClosureRecoveryState.state(agent_run).merge(
        "status" => "waiting", "next_retry_at" => next_retry_at.iso8601
      )
    ))
    agent_run.reload
  end

  it "queues a recovery for a run whose backoff window elapsed" do
    park(next_retry_at: 1.minute.ago)

    described_class.perform_now

    expect(RecoverSourceClosureAssessmentJob).to have_been_enqueued.with(agent_run.id)
  end

  it "does not queue a recovery before the backoff window elapsed" do
    park(next_retry_at: 30.minutes.from_now)

    described_class.perform_now

    expect(RecoverSourceClosureAssessmentJob).not_to have_been_enqueued
  end

  it "does not queue a recovery for a run that is not waiting" do
    park(next_retry_at: 1.minute.ago)
    agent_run.update!(reconciliation: agent_run.reconciliation.merge(
      "source_closure_recovery" => PartialCloseouts::SourceClosureRecoveryState.state(agent_run).merge("status" => "recovered")
    ))

    described_class.perform_now

    expect(RecoverSourceClosureAssessmentJob).not_to have_been_enqueued
  end
end
