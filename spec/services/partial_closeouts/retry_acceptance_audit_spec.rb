# frozen_string_literal: true

require "rails_helper"

# @spec PARTIAL-CLOSEOUT-056 AGENT-RETRY-005 AGENT-RETRY-006
RSpec.describe PartialCloseouts::RetryAcceptanceAudit do
  let(:account) { create(:account) }
  let(:owner) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: owner, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project:, github_state: "open", paid_state: "completed") }

  before do
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 12,
      github_state: "closed", pr_review_phase: "merged")
  end

  def failed_attempt(completed_at: 2.hours.ago, status: "failed")
    request = Issues::RequestAcceptanceAudit.call(issue:, actor: owner)
    request.agent_run.update!(status:, completed_at:,
      reconciliation: { "acceptance_audit_failure" => { "category" => "transport_error" } })
    request.agent_run
  end

  it "claims a bounded retry through the ordinary admission path and records lineage" do
    original = failed_attempt
    source_revision = original.continuation_request.evidence["source_revision"]

    result = described_class.call(agent_run_id: original.id, attempt: 2)

    expect(result).to be_claimed
    expect(result.successor.goal).to eq("analyze_issue")
    expect(result.successor.status).to eq("queued")
    expect(result.successor.continuation_request.evidence["continuation_mode"]).to eq("acceptance_audit")
    expect(result.successor.continuation_request.evidence["source_revision"]).to eq(source_revision)
    expect(result.successor.external_metadata[AgentRun::ACCEPTANCE_AUDIT_RETRY_ATTEMPT_METADATA_KEY]).to eq(2)
    expect(result.successor.external_metadata[AgentRun::ACCEPTANCE_AUDIT_RETRY_PARENT_METADATA_KEY]).to eq(original.id)
    expect(original.reload.status).to eq("retried")
    expect(issue.agent_runs.count).to eq(2)
  end

  it "links the superseded attempt to its replacement via the retry orchestration decision" do
    original = failed_attempt

    result = described_class.call(agent_run_id: original.id, attempt: 2)

    decision = OrchestrationDecision.where(agent_run: original, actor: described_class::DECISION_POINT).last
    expect(decision.outputs["new_agent_run_id"]).to eq(result.successor.id)
    expect(decision.inputs).to include("attempt" => 2, "max_attempts" => 3)
  end

  it "derives the next attempt number when none is supplied" do
    original = failed_attempt

    result = described_class.call(agent_run_id: original.id)

    expect(result).to be_claimed
    expect(result.successor.external_metadata[AgentRun::ACCEPTANCE_AUDIT_RETRY_ATTEMPT_METADATA_KEY]).to eq(2)
  end

  it "derives the next attempt number under the lock when the job payload is stale" do
    original = failed_attempt
    failed_attempt

    result = described_class.call(agent_run_id: original.id, attempt: 2)

    expect(result).to be_claimed
    expect(result.successor.external_metadata[AgentRun::ACCEPTANCE_AUDIT_RETRY_ATTEMPT_METADATA_KEY]).to eq(3)
  end

  it "is idempotent: a duplicate claim cannot mint a second successor" do
    original = failed_attempt

    first = described_class.call(agent_run_id: original.id, attempt: 2)
    second = described_class.call(agent_run_id: original.id, attempt: 2)

    expect(first).to be_claimed
    expect(second.outcome).to eq(:skipped)
    expect(second.reason).to eq(:already_retried)
    expect(issue.agent_runs.count).to eq(2)
  end

  it "refuses to collide with an operator's open audit authorization" do
    original = failed_attempt
    operator_request = Issues::RequestAcceptanceAudit.call(issue:, actor: owner)

    result = described_class.call(agent_run_id: original.id, attempt: 2)

    expect(result.outcome).to eq(:skipped)
    expect(result.reason).to eq(:open_request_present)
    expect(issue.agent_runs.count).to eq(2)
    expect(operator_request.agent_run.reload.status).to eq("queued")
  end

  it "refuses a stale retry after terminal evidence changed the logical identity" do
    original = failed_attempt
    create(:issue, :pull_request, project:, parent_issue: issue, github_number: 13,
      github_state: "closed", pr_review_phase: "merged")

    result = described_class.call(agent_run_id: original.id, attempt: 2)

    expect(result.reason).to eq(:evidence_changed)
    expect(issue.agent_runs.count).to eq(1)
    expect(original.reload.status).to eq("failed")
  end

  it "refuses a claim that arrives inside the backoff window" do
    original = failed_attempt(completed_at: 5.minutes.ago)

    result = described_class.call(agent_run_id: original.id, attempt: 2)

    expect(result.reason).to eq(:retry_backoff)
    expect(issue.agent_runs.count).to eq(1)
  end

  it "refuses a claim after the source revision's attempt budget is exhausted" do
    3.times { failed_attempt }

    result = described_class.call(agent_run_id: issue.agent_runs.order(:id).last.id, attempt: 4)

    expect(result.reason).to eq(:retry_budget_exhausted)
    expect(issue.agent_runs.count).to eq(3)
  end

  it "refuses a delayed claim whose supplied attempt is stale after the budget is spent" do
    delayed_run = failed_attempt
    2.times { failed_attempt }

    result = described_class.call(agent_run_id: delayed_run.id, attempt: 3)

    expect(result.reason).to eq(:retry_budget_exhausted)
    expect(issue.agent_runs.count).to eq(3)
    expect(delayed_run.reload.status).to eq("failed")
  end

  it "refuses a claim when the ordinary request path still refuses admission" do
    original = failed_attempt
    project.update!(auto_pick_enabled: false)

    result = described_class.call(agent_run_id: original.id, attempt: 2)

    expect(result.reason).to eq(:request_refused)
    expect(result.request_code).to eq(:automation_disabled)
    expect(issue.agent_runs.count).to eq(1)
    expect(original.reload.status).to eq("failed")
  end

  it "records a durable skip reason when it refuses a non-transient failure" do
    original = failed_attempt
    original.update!(status: "cancelled", reconciliation: {})

    result = described_class.call(agent_run_id: original.id, attempt: 2)

    expect(result.reason).to eq(:cancelled)
    decision = OrchestrationDecision.where(agent_run: original, actor: described_class::DECISION_POINT).last
    expect(decision).to be_present
    expect(decision.inputs).to include("reason" => "cancelled")
  end
end
