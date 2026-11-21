# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::AgentExecutionWorkflow do
  let(:workflow) { described_class.new }

  before do
    allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
  end

  # @spec TEMPORAL-ORCHESTRATION-016
  it "resolves ownership through the detached cancellation boundary on bounded poll/control capacity" do
    owned = { container: true, mcp_servers: false, services: false, worktree: false, janitor: true }
    allow(workflow).to receive(:run_cleanup_activity).and_return(owned)
    allow(workflow).to receive(:run_activity)

    result = workflow.resolve_cleanup_ownership(42)

    # run_cleanup_activity (not run_activity) is what keeps this call schedulable once the
    # workflow's own cancellation token is already cancelled — see base_workflow_spec.rb's
    # SDK-boundary coverage of that detachment. task_queue keeps this cheap metadata read off
    # the same agent-queue slots that a saturated long-agent pool would hold.
    expect(workflow).to have_received(:run_cleanup_activity).with(Activities::ResolveCleanupOwnershipActivity,
      { agent_run_id: 42 }, start_to_close_timeout: 10, schedule_to_close_timeout: 30,
      retry_policy: described_class::NO_RETRY, task_queue: Paid.poll_task_queue)
    expect(workflow).not_to have_received(:run_activity)
    expect(result).to eq(owned)
  end

  # @spec TEMPORAL-ORCHESTRATION-016
  it "fails safe to legacy cleanup when the detached resolver call errors, without re-raising cancellation" do
    allow(workflow).to receive(:run_cleanup_activity).and_raise(Temporalio::Error::CanceledError.new("cancelled"))

    expect(workflow.resolve_cleanup_ownership(42)).to eq(workflow.legacy_cleanup_ownership)
  end

  # @spec TEMPORAL-ORCHESTRATION-016
  it "preserves legacy cleanup ownership for an unpatched history without calling the activity" do
    allow(Temporalio::Workflow).to receive(:patched).with("cleanup-owned-resources-v1").and_return(false)
    allow(workflow).to receive(:run_cleanup_activity)

    expect(workflow.resolve_cleanup_ownership(42)).to eq(workflow.legacy_cleanup_ownership)
    expect(workflow).not_to have_received(:run_cleanup_activity)
  end

  # These two examples stub the real SDK boundary (Temporalio::Workflow.execute_activity)
  # instead of our own run_activity/run_cleanup_activity wrappers, the same technique
  # base_workflow_spec.rb uses to prove the detached-cancellation contract. The fake
  # raises CanceledError unless called with an explicit `cancellation:` kwarg, mirroring
  # how a genuinely already-cancelled ambient workflow token behaves against the real
  # Temporal SDK — the regression an ordinary `run_activity` call would hit here.
  describe "at the real SDK boundary, with the ambient workflow token already cancelled" do
    def stub_cancelled_ambient_token(ownership_result:)
      allow(Temporalio::Workflow).to receive(:execute_activity) do |activity_class, _input, **options|
        raise Temporalio::Error::CanceledError, "workflow canceled" unless options.key?(:cancellation)

        activity_class == Activities::ResolveCleanupOwnershipActivity ? ownership_result : {}
      end
    end

    # @spec TEMPORAL-ORCHESTRATION-016
    it "still schedules owned-resource cleanup when ownership is persisted" do
      stub_cancelled_ambient_token(ownership_result: { container: true, mcp_servers: false,
        services: false, worktree: false, janitor: false })

      ownership = workflow.resolve_cleanup_ownership(42)
      workflow.send(:run_cleanup_activity, Activities::CleanupContainerActivity,
        { agent_run_id: 42 }, timeout: 30) if ownership[:container]

      expect(Temporalio::Workflow).to have_received(:execute_activity)
        .with(Activities::ResolveCleanupOwnershipActivity, anything, any_args).once
      expect(Temporalio::Workflow).to have_received(:execute_activity)
        .with(Activities::CleanupContainerActivity, anything, any_args).once
    end

    # @spec TEMPORAL-ORCHESTRATION-016
    it "schedules only the resolver call itself for an empty acceptance-audit ownership result" do
      stub_cancelled_ambient_token(ownership_result: {})

      ownership = workflow.resolve_cleanup_ownership(42)

      expect(ownership).to eq({})
      expect(Temporalio::Workflow).to have_received(:execute_activity)
        .with(Activities::ResolveCleanupOwnershipActivity, anything, any_args).once
      expect(Temporalio::Workflow).not_to have_received(:execute_activity)
        .with(Activities::CleanupContainerActivity, anything, any_args)
    end
  end
end
