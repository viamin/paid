# frozen_string_literal: true

require "rails_helper"

RSpec.describe PartialCloseouts::Advance do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account: account) }
  let(:project) { create(:project, account: account, created_by: owner, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project: project, github_state: "open", paid_state: "in_progress") }
  let(:run) do
    create(:agent_run, :completed, project: project, issue: issue, goal: "create_pr",
      pull_request_number: 12, pull_request_url: "https://github.com/acme/alpha/pull/12", completed_at: 2.days.ago)
  end

  before do
    create(:issue, :pull_request, project: project, parent_issue: issue, github_number: 12,
      github_state: "closed", pr_review_phase: "merged")
  end

  # @spec PARTIAL-CLOSEOUT-024
  it "automatically schedules one fresh acceptance audit after stale gaps have shipped" do
    result = described_class.call(agent_run: run, assessment: { "gaps" => [] })

    expect(result.scheduled?).to be(true)
    expect(result.agent_run.trigger_type).to eq("automatic")
    expect(result.agent_run.auto_pick).to be(true)
    expect(result.agent_run.continuation_request.reason).to include("fresh acceptance audit")
    expect(run.reload.reconciliation.dig("advance", "outcome")).to eq("scheduled")
  end

  # @spec PARTIAL-CLOSEOUT-024
  it "does not schedule an audit while focused implementation work remains" do
    result = described_class.call(agent_run: run, assessment: { "gaps" => [ { "criterion" => "dispatch" } ] })

    expect(result.scheduled?).to be(false)
    expect(issue.reload.agent_runs.where.not(id: run.id)).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-024
  it "respects disabled automation and leaves the issue for normal visibility" do
    project.update!(auto_pick_enabled: false)

    result = described_class.call(agent_run: run, assessment: { "gaps" => [] })

    expect(result.scheduled?).to be(false)
    expect(result.code).to eq(:automation_disabled)
    expect(run.reload.reconciliation.dig("advance", "outcome")).to eq("waiting")
    expect(IssueContinuationRequest.where(issue: issue)).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-024
  it "does not bypass an explicit hold" do
    issue.update_columns(paused: true)

    result = described_class.call(agent_run: run, assessment: { "gaps" => [] })

    expect(result.scheduled?).to be(false)
    expect(result.code).to eq(:operator_pause)
    expect(IssueContinuationRequest.where(issue: issue)).to be_empty
  end

  # @spec PARTIAL-CLOSEOUT-024
  it "is replay-safe when concurrent recovery sees an existing authorization" do
    first = described_class.call(agent_run: run, assessment: { "gaps" => [] })
    second = described_class.call(agent_run: run, assessment: { "gaps" => [] })

    expect(first.scheduled?).to be(true)
    expect(second.scheduled?).to be(true)
    expect(IssueContinuationRequest.where(issue: issue).count).to eq(1)
    expect(issue.agent_runs.where(goal: "create_pr").count).to eq(2)
  end
end
