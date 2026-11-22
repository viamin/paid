# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::PrioritizeCodingRetry do # @spec QUEUE-TIER-008
  let(:account) { create(:account) }
  let(:actor) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: actor) }
  let(:issue) { create(:issue, project:) }
  let(:request) do
    create(:issue_continuation_request, project:, issue:, requested_by: actor,
      evidence: { "continuation_mode" => "implementation", "source_revision" => "retained-source" })
  end
  let(:agent_run) do
    create(:agent_run, project:, issue:, continuation_request: request, goal: "create_pr",
      trigger_type: "automatic", auto_pick: true, initiating_user: actor,
      external_metadata: { AgentRun::MANUAL_RETRY_ATTEMPT_METADATA_KEY => 2, "retried_from_agent_run_id" => 44 })
  end

  def prioritize
    described_class.call(agent_run:, actor:)
  end

  it "records one request without changing the existing retry's authority or identity" do
    original = agent_run.attributes.slice("trigger_type", "auto_pick", "runner_id", "execution_origin",
      "external_metadata", "continuation_request_id", "source_pull_request_number", "base_commit_sha")

    expect(prioritize).to be(true)

    expect(agent_run.reload.operator_coding_priority_requested_at).to be_present
    expect(agent_run.attributes.slice(*original.keys)).to eq(original)
    event = account.account_activity_events.find_by!(action: "agent_run.coding_priority_requested")
    expect(event).to have_attributes(actor:, subject: agent_run)
    expect(event.metadata).to include("original_trigger_type" => "automatic", "continuation_request_id" => request.id)
  end

  it "converges repeated requests on the first timestamp and event" do
    prioritize
    timestamp = agent_run.reload.operator_coding_priority_requested_at

    expect(prioritize).to be(false)
    expect(agent_run.reload.operator_coding_priority_requested_at).to eq(timestamp)
    expect(account.account_activity_events.where(action: "agent_run.coding_priority_requested").count).to eq(1)
  end

  it "rejects a cross-account actor without changing priority" do
    expect { described_class.call(agent_run:, actor: create(:user)) }.to raise_error(Pundit::NotAuthorizedError)

    expect(agent_run.reload.operator_coding_priority_requested_at).to be_nil
  end

  it "leaves claimed, running, terminal, rate-limited, and audit work unchanged" do
    [
      -> { agent_run.update!(temporal_workflow_id: "already-claimed") },
      -> { agent_run.update!(status: "running", started_at: Time.current) },
      -> { agent_run.update!(status: "cancelled", completed_at: Time.current) },
      -> { agent_run.update!(status: "rate_limited", rate_limited_until: 1.hour.from_now) },
      -> { agent_run.update!(goal: "analyze_issue") }
    ].each do |transition|
      transition.call
      expect(prioritize).to be(false)
      expect(agent_run.reload.operator_coding_priority_requested_at).to be_nil
      agent_run.reload.update!(status: "queued", temporal_workflow_id: nil, started_at: nil, completed_at: nil,
        rate_limited_until: nil, goal: "create_pr")
    end
  end

  it "does not prioritize an automatic run without retry or continuation authority" do
    agent_run.update!(continuation_request: nil, source_pull_request_number: nil)

    expect(prioritize).to be(false)
    expect(agent_run.reload.operator_coding_priority_requested_at).to be_nil
  end

  it "prioritizes a bounded automatic root retry without inventing source or continuation lineage" do # @spec QUEUE-TIER-008
    create(:agent_run, :failed, :automatic, project:, issue:, goal: "create_pr", auto_pick: true,
      completed_at: 1.minute.ago)
    agent_run.update!(continuation_request: nil, source_pull_request_number: nil)
    request.destroy!
    original = agent_run.attributes.slice("trigger_type", "execution_origin", "external_metadata",
      "continuation_request_id", "source_pull_request_number", "runner_id")

    expect(prioritize).to be(true)

    expect(agent_run.reload.attributes.slice(*original.keys)).to eq(original)
    expect(agent_run.operator_coding_priority_requested_at).to be_present
  end

  it "keeps an expired backoff timestamp while allowing the same retry to be prioritized" do
    agent_run.update!(rate_limited_until: 1.minute.ago)

    expect(prioritize).to be(true)
    expect(agent_run.reload.rate_limited_until).to be_within(1.second).of(1.minute.ago)
  end
end
