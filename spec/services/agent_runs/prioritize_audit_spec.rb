# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::PrioritizeAudit do # @spec QUEUE-TIER-007
  let(:account) { create(:account) }
  let(:actor) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: actor) }
  let(:issue) { create(:issue, project:) }
  let(:request) do
    create(:issue_continuation_request, project:, issue:, requested_by: actor,
      evidence: { "continuation_mode" => "acceptance_audit", "source_revision" => "retained-source" })
  end
  let(:agent_run) do
    create(:agent_run, project:, issue:, continuation_request: request, goal: "analyze_issue",
      trigger_type: "automatic", auto_pick: true, initiating_user: actor,
      external_metadata: { AgentRun::ACCEPTANCE_AUDIT_RETRY_ATTEMPT_METADATA_KEY => 2 })
  end

  def prioritize
    described_class.call(agent_run:, actor:)
  end

  it "records one scheduling request and actor event without changing admission or retry identity" do
    original = agent_run.attributes.slice("trigger_type", "auto_pick", "runner_id", "external_metadata",
      "continuation_request_id", "base_commit_sha")
    evidence = request.evidence.deep_dup

    expect(prioritize).to be(true)

    expect(agent_run.reload.operator_priority_requested_at).to be_present
    expect(agent_run.attributes.slice(*original.keys)).to eq(original)
    expect(request.reload.evidence).to eq(evidence)
    event = account.account_activity_events.find_by!(action: "agent_run.audit_priority_requested")
    expect(event).to have_attributes(actor:, subject: agent_run)
    expect(event.metadata).to include("original_trigger_type" => "automatic", "continuation_request_id" => request.id)
  end

  it "converges repeated requests on the first timestamp and event" do
    prioritize
    timestamp = agent_run.reload.operator_priority_requested_at

    expect(prioritize).to be(false)

    expect(agent_run.reload.operator_priority_requested_at).to eq(timestamp)
    expect(account.account_activity_events.where(action: "agent_run.audit_priority_requested").count).to eq(1)
  end

  it "uses operator queue ordering while preserving the automatic trigger" do
    create(:agent_run, project:, source_pull_request_number: 42, trigger_type: "automatic")

    prioritize

    expect(agent_run.reload.queue_priority_tier).to eq(:manual)
    expect(agent_run.queue_priority_label).to eq("1 - Operator-requested audit")
    expect(AgentRun.next_queued_run).to eq(agent_run)
    expect(agent_run.trigger_type).to eq("automatic")
  end

  it "rejects a cross-account actor without changing priority" do
    foreign_actor = create(:user)

    expect { described_class.call(agent_run:, actor: foreign_actor) }.to raise_error(Pundit::NotAuthorizedError)

    expect(agent_run.reload.operator_priority_requested_at).to be_nil
    expect(account.account_activity_events.where(action: "agent_run.audit_priority_requested")).to be_empty
  end

  it "leaves claimed work unchanged" do
    agent_run.update!(temporal_workflow_id: "already-claimed")

    expect(prioritize).to be(false)
    expect(agent_run.reload.operator_priority_requested_at).to be_nil
  end

  it "enforces the project run permission within the actor's account" do
    policy = instance_double(ProjectPolicy, run_agent?: false)
    allow(ProjectPolicy).to receive(:new).with(actor, project).and_return(policy)

    expect { prioritize }.to raise_error(Pundit::NotAuthorizedError)

    expect(agent_run.reload.operator_priority_requested_at).to be_nil
  end

  it "leaves running work unchanged" do
    agent_run.update!(status: "running", started_at: Time.current)

    expect(prioritize).to be(false)
    expect(agent_run.reload.operator_priority_requested_at).to be_nil
  end

  it "leaves terminal work unchanged" do
    agent_run.update!(status: "cancelled", completed_at: Time.current)

    expect(prioritize).to be(false)
    expect(agent_run.reload.operator_priority_requested_at).to be_nil
  end

  it "does not prioritize an implementation authorization" do
    request.update!(evidence: request.evidence.merge("continuation_mode" => "implementation"))

    expect(prioritize).to be(false)
    expect(agent_run.reload.operator_priority_requested_at).to be_nil
  end

  it "keeps existing manual work at its original priority" do
    agent_run.update!(trigger_type: "manual")

    expect(prioritize).to be(false)
    expect(agent_run.reload.operator_priority_requested_at).to be_nil
    expect(agent_run.queue_priority_label).to eq("1 - Manual")
  end

  it "rolls back the priority request when the actor audit cannot be recorded" do
    agent_run
    allow(Audit::RecordEvent).to receive(:call).and_raise("audit unavailable")

    expect { prioritize }.to raise_error("audit unavailable")

    expect(agent_run.reload.operator_priority_requested_at).to be_nil
  end
end
