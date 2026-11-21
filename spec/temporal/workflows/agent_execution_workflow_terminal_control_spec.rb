# frozen_string_literal: true

require "rails_helper"

RSpec.describe Workflows::AgentExecutionWorkflow do
  let(:workflow) { described_class.new }
  let(:input) do
    { project_id: 19, issue_id: 100, agent_run_id: 42,
      goal: "analyze_issue", continuation_mode: "acceptance_audit" }
  end
  let(:primary_error) { Temporalio::Error::ApplicationError.new("audit unavailable", type: "AuditUnavailable") }
  let(:bookkeeping_error) do
    Temporalio::Error::ActivityError.new("control unavailable", scheduled_event_id: 5,
      started_event_id: 0, identity: "", activity_type: "MarkAgentRunFailed", activity_id: "5",
      retry_state: Temporalio::Error::RetryState::TIMEOUT)
  end
  let(:calls) { [] }

  before do
    allow(Temporalio::Workflow).to receive_messages(logger: Rails.logger, patched: true)
    allow(workflow).to receive_messages(current_workflow_id: "terminal-control-test",
      check_quality_gate: { allowed: true }, run_cleanup_activity: {})
    allow(workflow).to receive(:run_activity) do |activity, data, **options|
      calls << { activity:, data:, options: }
      case activity.name
      when "Activities::CreateAgentRunActivity"
        { agent_run_id: 42 }
      when "Activities::RunAcceptanceAuditActivity"
        raise primary_error
      else
        {}
      end
    end
  end

  def failure_publication
    calls.find { |call| call[:activity] == Activities::MarkAgentRunFailedActivity }
  end

  # @spec TEMPORAL-ORCHESTRATION-015
  it "publishes an actual audit failure through bounded control capacity while keeping analysis on its original queue" do
    expect { workflow.execute(input) }.to raise_error(primary_error)

    expect(failure_publication).to include(
      data: { agent_run_id: 42, error: "audit unavailable", failure_type: "AuditUnavailable" },
      options: { timeout: 30, schedule_to_close_timeout: 120, task_queue: Paid.poll_task_queue }
    )
    audit = calls.find { |call| call[:activity] == Activities::RunAcceptanceAuditActivity }
    expect(audit[:options]).not_to have_key(:task_queue)
    expect(workflow).to have_received(:run_cleanup_activity).with(Activities::CleanupContainerActivity, anything, any_args)
  end

  # @spec TEMPORAL-ORCHESTRATION-015
  it "uses the same control path when a quality gate rejects the run before analysis" do
    allow(workflow).to receive(:check_quality_gate).and_return(allowed: false, reason: "quality_gate_breached", breaches: [])

    expect(workflow.execute(input)).to include(success: false, quality_gate_blocked: true)
    expect(failure_publication[:options]).to include(task_queue: Paid.poll_task_queue, schedule_to_close_timeout: 120)
    expect(calls.map { |call| call[:activity] }).not_to include(Activities::RunAcceptanceAuditActivity)
  end

  # @spec TEMPORAL-ORCHESTRATION-015
  it "publishes a startup rejection for the original run without admitting another execution" do
    allow(workflow).to receive(:run_activity).with(Activities::CreateAgentRunActivity, anything, any_args).and_raise(primary_error)

    expect { workflow.execute(input) }.to raise_error(primary_error)
    expect(failure_publication[:data]).to include(agent_run_id: 42, error: "audit unavailable")
    expect(failure_publication[:options]).to include(task_queue: Paid.poll_task_queue)
    expect(calls.map { |call| call[:activity] }).not_to include(Activities::RunAcceptanceAuditActivity)
  end

  # @spec TEMPORAL-ORCHESTRATION-015
  it "preserves the original failure and normal cleanup when control publication itself fails" do
    allow(workflow).to receive(:run_activity).with(Activities::MarkAgentRunFailedActivity, anything, any_args).and_raise(bookkeeping_error)
    allow(Rails.logger).to receive(:warn)

    expect { workflow.execute(input) }.to raise_error(primary_error)
    expect(Rails.logger).to have_received(:warn).with(hash_including(message: "agent_execution.failure_bookkeeping_unavailable", agent_run_id: 42))
    expect(workflow).to have_received(:run_cleanup_activity).with(Activities::EnqueueJanitorActivity, anything, any_args)
  end

  # @spec TEMPORAL-ORCHESTRATION-015
  it "preserves legacy routing, bounds and secondary-error propagation for an unpatched history" do
    allow(Temporalio::Workflow).to receive(:patched).with("failure-bookkeeping-control-v1").and_return(false)

    expect { workflow.execute(input) }.to raise_error(primary_error)
    expect(failure_publication[:options]).to eq(timeout: 30)

    allow(workflow).to receive(:run_activity).with(Activities::MarkAgentRunFailedActivity, anything, any_args).and_raise(bookkeeping_error)
    expect { workflow.execute(input) }.to raise_error(bookkeeping_error)
  end

  # @spec TEMPORAL-ORCHESTRATION-015
  it "propagates cancellation without publishing a fabricated failed status" do
    cancellation = Temporalio::Error::CanceledError.new("cancelled")
    allow(workflow).to receive(:run_activity).with(Activities::RunAcceptanceAuditActivity, anything, any_args).and_raise(cancellation)

    expect { workflow.execute(input) }.to raise_error(cancellation)
    expect(failure_publication).to be_nil
    expect(workflow).to have_received(:run_cleanup_activity).with(Activities::CleanupContainerActivity, anything, any_args)
  end
end
