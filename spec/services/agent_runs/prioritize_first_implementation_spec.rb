# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::PrioritizeFirstImplementation do # @spec QUEUE-TIER-010
  let(:account) { create(:account) }
  let(:actor) { create(:user, account:) }
  let(:project) { create(:project, account:, created_by: actor, auto_pick_enabled: true) }
  let(:issue) { create(:issue, project:, github_state: "open") }
  let(:agent_run) do
    create(:agent_run, :queued, :automatic, project:, issue:, goal: "create_pr", auto_pick: true,
      initiating_user: actor, execution_origin: "paid_native")
  end

  it "records scheduling intent for the same genuine first automatic implementation" do
    original = agent_run.attributes.slice("trigger_type", "auto_pick", "execution_origin", "runner_id",
      "external_metadata", "continuation_request_id", "source_pull_request_number", "base_commit_sha")

    expect(described_class.call(agent_run:, actor:)).to be(true)

    expect(agent_run.reload.operator_coding_priority_requested_at).to be_present
    expect(agent_run.attributes.slice(*original.keys)).to eq(original)
    expect(account.account_activity_events.find_by!(action: "agent_run.first_implementation_priority_requested"))
      .to have_attributes(actor:, subject: agent_run)
  end

  it "converges repeated requests without another audit event" do
    expect(described_class.call(agent_run:, actor:)).to be(true)
    timestamp = agent_run.reload.operator_coding_priority_requested_at

    expect(described_class.call(agent_run:, actor:)).to be(false)
    expect(agent_run.reload.operator_coding_priority_requested_at).to eq(timestamp)
    expect(account.account_activity_events.where(action: "agent_run.first_implementation_priority_requested").count).to eq(1)
  end

  it "refuses priority while the project is quality paused" do # @spec QUEUE-TIER-010
    project.update!(quality_paused_at: 1.hour.ago)

    expect(described_class.call(agent_run:, actor:)).to be(false)
    expect(agent_run.reload.operator_coding_priority_requested_at).to be_nil
    expect(account.account_activity_events.where(action: "agent_run.first_implementation_priority_requested")).not_to exist
  end

  [
    { started_at: 1.minute.ago },
    { container_id: "retained-container" },
    { runner_handle: { "identifier" => "retained-runner" } },
    { worktree_path: "/private/retained-worktree" },
    { service_container_ids: [ "retained-service" ] }
  ].each do |ownership|
    it "refuses priority with retained #{ownership.keys.first}" do # @spec QUEUE-TIER-010
      agent_run.update!(ownership)

      expect(described_class.call(agent_run:, actor:)).to be(false)
      expect(agent_run.reload.operator_coding_priority_requested_at).to be_nil
      expect(agent_run.operator_first_implementation_priority_requested_at).to be_nil
      expect(account.account_activity_events.where(action: "agent_run.first_implementation_priority_requested")).not_to exist
    end
  end

  it "refuses priority for a run with an active worktree association" do # @spec QUEUE-TIER-010
    create(:worktree, :active, project:, agent_run:)

    expect(described_class.call(agent_run:, actor:)).to be(false)
    expect(agent_run.reload.operator_coding_priority_requested_at).to be_nil
    expect(account.account_activity_events.where(action: "agent_run.first_implementation_priority_requested")).not_to exist
  end

  it "rejects cross-tenant actors and invalidated, delayed, retry, and exhausted sources" do
    expect { described_class.call(agent_run:, actor: create(:user)) }.to raise_error(Pundit::NotAuthorizedError)

    [
      -> { agent_run.update!(rate_limited_until: 1.hour.from_now) },
      -> { create(:agent_run, :failed, :automatic, project:, issue:, goal: "create_pr", auto_pick: true, created_at: 1.minute.ago) },
      -> { agent_run.update!(source_pull_request_number: 99) }
    ].each do |change|
      change.call
      expect(described_class.call(agent_run:, actor:)).to be(false)
      expect(agent_run.reload.operator_coding_priority_requested_at).to be_nil
      agent_run.update!(rate_limited_until: nil, source_pull_request_number: nil)
      issue.agent_runs.where.not(id: agent_run.id).delete_all
    end
  end
end
