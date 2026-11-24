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

  it "refuses a guardrail exhaustion without resetting its execution budget" do
    run = create(:agent_run, :timeout, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false,
      guardrail_violation_type: "time_limit")

    expect(policy.assess(run)).to have_attributes(eligible?: false, reason: :execution_budget_exhausted)
  end

  it "rechecks project opt-out and pause" do
    run = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false)
    project.update!(retry_failed_manual_runs: false)
    expect(policy.assess(run)).to have_attributes(eligible?: false, reason: :project_retry_disabled)

    project.update!(retry_failed_manual_runs: true, paused: true)
    expect(policy.assess(run)).to have_attributes(eligible?: false, reason: :project_or_issue_paused)
  end
end
