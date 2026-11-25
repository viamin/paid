# frozen_string_literal: true

require "rails_helper"

# @spec MANUAL-RUN-RETRY-010 AGENT-RETRY-019 EAGER-QUEUE-019
RSpec.describe RetryFailedManualIssueCreatePrJob do
  let(:project) { create(:project, auto_pick_enabled: false, retry_failed_manual_runs: true) }
  let(:issue) { create(:issue, project:, paid_state: "failed", github_state: "open") }

  it "creates one manual successor without enabling auto-pick" do
    original = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false)

    expect { described_class.new.perform(original.id, 1) }
      .to change(AgentRun, :count).by(1).and have_enqueued_job(ProcessRunQueueJob)

    successor = AgentRun.order(:id).last
    expect(successor).to have_attributes(project:, issue:, trigger_type: "manual", auto_pick: false, status: "queued")
    expect(successor.external_metadata).to include("manual_retry_attempt" => 1, "retried_from_agent_run_id" => original.id)
    expect(original.reload.status).to eq("retried")
  end

  it "does not duplicate a delayed delivery or replace an active successor" do
    original = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false)

    2.times { described_class.new.perform(original.id, 1) }

    expect(AgentRun.where(project:, issue:, goal: "create_pr", status: "queued").count).to eq(1)
  end

  it "refuses a source that changed or now has preserved work" do
    original = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false,
      result_commit_sha: "a" * 40)

    expect { described_class.new.perform(original.id, 1) }.not_to change(AgentRun, :count)
    expect(OrchestrationDecision.last.outputs).to include("reason" => "implementation_work_produced")
  end

  it "retains the failed implementation lineage when another goal owns parked work" do
    original = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false)
    parked = create(:agent_run, project:, issue:, goal: "analyze_issue", status: "rate_limited",
      rate_limited_until: 1.hour.from_now)

    expect { described_class.new.perform(original.id, 1) }.not_to change(AgentRun, :count)

    expect(original.reload).to have_attributes(status: "failed", manual_retry_attempt: 0)
    expect(parked.reload.status).to eq("rate_limited")
  end

  it "rechecks ownership when another goal is admitted after the first assessment" do
    original = create(:agent_run, :failed, project:, issue:, goal: "create_pr", trigger_type: "manual", auto_pick: false)
    policy = AgentRuns::ManualIssueCreatePrRetryPolicy.new
    allow(AgentRuns::ManualIssueCreatePrRetryPolicy).to receive(:new).and_return(policy)
    allow(policy).to receive(:build_successor!).and_wrap_original do |build, *args|
      Activities::QueueAgentRunActivity.new.execute(
        project_id: project.id, issue_id: issue.id, goal: "analyze_issue", trigger_type: "manual")
      build.call(*args)
    end

    expect { described_class.new.perform(original.id, 1) }.to change(AgentRun, :count).by(1)

    expect(AgentRun.where(project:, issue:, status: "queued").pluck(:goal)).to eq([ "analyze_issue" ])
    expect(original.reload).to have_attributes(status: "failed", manual_retry_attempt: 0)
    expect(OrchestrationDecision.last.outputs).to include("reason" => "not_admitted")
  end
end
