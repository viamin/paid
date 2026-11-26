# frozen_string_literal: true

require "rails_helper"

# @spec MANUAL-RUN-RETRY-010 AGENT-RETRY-019 EAGER-QUEUE-019
RSpec.describe AgentRuns::ManualIssueCreatePrRetryPolicy do
  subject(:policy) { described_class.new }

  let(:project) { create(:project, auto_pick_enabled: false, retry_failed_manual_runs: true) }
  let(:issue) { create(:issue, project:, paid_state: "failed", github_state: "open") }

  describe "enqueue outcome" do
    let(:run) { create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false) }
    let(:retry_attempt) { RetryableAttempts::RetryAttempt.new(policy:, decision_point: "enqueue_outcome") }
    let!(:configured_job) { RetryFailedManualIssueCreatePrJob.set(wait: 5.seconds) }

    before do
      allow(RetryFailedManualIssueCreatePrJob).to receive(:set).with(wait: 5.seconds).and_return(configured_job)
    end

    [ false, nil ].each do |enqueue_result|
      it "records refusal when Active Job returns #{enqueue_result.inspect}" do
        allow(configured_job).to receive(:perform_later).with(run.id, 1).and_return(enqueue_result)

        result = retry_attempt.schedule(attempt: run, job_class: RetryFailedManualIssueCreatePrJob, delay: ->(_) { 5.seconds })

        expect(result).to have_attributes(outcome: :skipped, reason: :enqueue_declined)
        decision = OrchestrationDecision.where(agent_run: run, decision_type: "manual_issue_create_pr_failed_run_retry").sole
        expect(decision.context).to include("decision_status" => "noop")
        expect(run.reload).to have_attributes(status: "failed", manual_retry_attempt: 0)
      end
    end

    it "records scheduling after a confirmed enqueue without claiming a successor" do
      result = nil
      expect {
        result = retry_attempt.schedule(attempt: run, job_class: RetryFailedManualIssueCreatePrJob, delay: ->(_) { 5.seconds })
      }.to have_enqueued_job(RetryFailedManualIssueCreatePrJob).with(run.id, 1)

      expect(result).to be_scheduled
      decision = OrchestrationDecision.where(agent_run: run, decision_type: "manual_issue_create_pr_failed_run_retry").sole
      expect(decision.context).to include("decision_status" => "scheduled")
      expect(run.reload).to have_attributes(status: "failed", manual_retry_attempt: 0)
    end
  end

  it "admits a no-work manual issue run without enabling auto-pick discovery" do
    run = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false)

    expect(policy.assess(run)).to have_attributes(eligible?: true, reason: :eligible, attempt: 1)
  end

  it "refuses preserved partial work" do
    run = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false,
      result_commit_sha: "a" * 40)

    expect(policy.assess(run)).to have_attributes(eligible?: false, reason: :implementation_work_produced)
  end

  it "refuses a retained unpublished result before its execution counters record work" do
    run = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false,
      unpublished_result_commit_sha: "b" * 40)

    expect(run.result_commit_sha).to be_blank
    expect(run).to be_no_observable_work
    expect(policy.assess(run)).to have_attributes(eligible?: false, reason: :implementation_work_produced)
  end

  it "retains a rate-limited sibling as the active implementation owner" do
    run = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false)
    parked = create(:agent_run, project:, issue:, goal: "create_pr", status: "rate_limited",
      rate_limited_until: 1.hour.from_now)

    assessment = policy.assess(run)

    expect(assessment).to have_attributes(eligible?: false, reason: :existing_active_run)
    expect(assessment.existing_run&.id).to eq(parked.id)
  end

  it "refuses a guardrail exhaustion without resetting its execution budget" do
    run = create(:agent_run, :timeout, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false,
      guardrail_violation_type: "time_limit")

    expect(policy.assess(run)).to have_attributes(eligible?: false, reason: :execution_budget_exhausted)
  end

  it "retains a rate-limited sibling with a different goal as the issue owner" do
    run = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false)
    parked = create(:agent_run, project:, issue:, goal: "analyze_issue", status: "rate_limited",
      rate_limited_until: 1.hour.from_now)

    assessment = policy.assess(run)

    expect(assessment).to have_attributes(eligible?: false, reason: :existing_active_run)
    expect(assessment.existing_run&.id).to eq(parked.id)
    expect { policy.assess(run) }.not_to change(AgentRun, :count)
    expect(parked.reload).to have_attributes(status: "rate_limited", completed_at: nil)
  end

  it "rechecks project opt-out and pause" do
    run = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false)
    project.update!(retry_failed_manual_runs: false)
    expect(policy.assess(run)).to have_attributes(eligible?: false, reason: :project_retry_disabled)

    project.update!(retry_failed_manual_runs: true, paused: true)
    expect(policy.assess(run)).to have_attributes(eligible?: false, reason: :project_or_issue_paused)
  end

  it "refuses recovery when the current hard-stop cost budget is exhausted" do
    run = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false)
    create(:cost_budget, :hard_stop, project:, current_usage_cents: 100_000)

    expect(policy.assess(run)).to have_attributes(eligible?: false, reason: :cost_budget_exhausted)
  end

  it "carries the operator-authorized review depth snapshot onto the successor" do
    run = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false,
      review_depth_snapshot: "focused")

    successor = policy.build_successor!(run, 1)

    expect(successor.review_depth_snapshot).to eq("focused")
  end

  it "carries the maintenance context snapshot onto the successor" do
    run = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false,
      maintenance_type: "dependency_upgrade", base_commit_sha: "b" * 40)

    successor = policy.build_successor!(run, 1)

    expect(successor).to have_attributes(maintenance_type: "dependency_upgrade", base_commit_sha: "b" * 40)
  end
end
