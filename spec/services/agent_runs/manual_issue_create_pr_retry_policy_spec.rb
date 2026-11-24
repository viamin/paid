# frozen_string_literal: true

require "rails_helper"

# @spec MANUAL-RUN-RETRY-010 AGENT-RETRY-019 EAGER-QUEUE-019
RSpec.describe AgentRuns::ManualIssueCreatePrRetryPolicy do
  subject(:policy) { described_class.new }

  let(:project) { create(:project, auto_pick_enabled: false, retry_failed_manual_runs: true) }
  let(:issue) { create(:issue, project:, paid_state: "failed", github_state: "open") }

  it "admits a no-work manual issue run without enabling auto-pick discovery" do
    run = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false)

    expect(policy.assess(run)).to have_attributes(eligible?: true, reason: :eligible, attempt: 1)
  end

  it "refuses preserved partial work" do
    run = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false,
      result_commit_sha: "a" * 40)

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
