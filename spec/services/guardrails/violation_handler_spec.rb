# frozen_string_literal: true

require "rails_helper"

RSpec.describe Guardrails::ViolationHandler do
  describe ".call" do
    let(:agent_run) { create(:agent_run, :running) }

    before do
      allow(AgentRuns::Cancel).to receive(:call)
    end

    it "pauses the agent run on loop detection" do
      result = described_class.call(
        agent_run: agent_run,
        violation_type: "loop_detected",
        details: "5 consecutive identical outputs"
      )

      expect(result.paused?).to be true
      expect(result.violation_type).to eq("loop_detected")
      expect(agent_run.reload.status).to eq("paused")
      expect(agent_run.guardrail_violation_type).to eq("loop_detected")
      expect(agent_run.paused_at).to be_present
      expect(AgentRuns::Cancel).to have_received(:call).with(agent_run: agent_run, skip_status_update: true)
    end

    it "pauses the agent run on token limit violation" do
      result = described_class.call(
        agent_run: agent_run,
        violation_type: "token_limit",
        details: "Token usage exceeded 100000 limit",
        metrics: { max_tokens: 100_000 }
      )

      expect(result.paused?).to be true
      expect(agent_run.reload.status).to eq("paused")
      expect(agent_run.guardrail_violation_type).to eq("token_limit")
    end

    it "pauses the agent run on cost limit violation" do
      result = described_class.call(
        agent_run: agent_run,
        violation_type: "cost_limit",
        details: "Per-run budget exceeded: 500 of 400 cents"
      )

      expect(result.paused?).to be true
      expect(agent_run.reload.guardrail_violation_type).to eq("cost_limit")
    end

    it "pauses the agent run on time limit violation" do
      result = described_class.call(
        agent_run: agent_run,
        violation_type: "time_limit",
        details: "Execution exceeded 3600s limit"
      )

      expect(result.paused?).to be true
      expect(agent_run.reload.guardrail_violation_type).to eq("time_limit")
    end

    it "pauses the agent run on anomaly detection" do
      result = described_class.call(
        agent_run: agent_run,
        violation_type: "anomaly",
        details: "Unusual CPU usage pattern detected"
      )

      expect(result.paused?).to be true
      expect(agent_run.reload.guardrail_violation_type).to eq("anomaly")
    end

    it "stores violation context as structured data" do
      described_class.call(
        agent_run: agent_run,
        violation_type: "loop_detected",
        details: "Repeated output",
        metrics: { repeated_count: 5 }
      )

      context = agent_run.reload.guardrail_context
      expect(context["violation_type"]).to eq("loop_detected")
      expect(context["details"]).to eq("Repeated output")
      expect(context["triggered_at"]).to be_present
      expect(context["metrics"]).to include("repeated_count" => 5)
      expect(context["recommended_action"]).to be_present
    end

    it "includes current run metrics in context" do
      agent_run.update!(iterations: 10, tokens_input: 5000, tokens_output: 2000, cost_cents: 75)

      described_class.call(
        agent_run: agent_run,
        violation_type: "token_limit",
        details: "Token limit exceeded"
      )

      metrics = agent_run.reload.guardrail_context["metrics"]
      expect(metrics["iterations"]).to eq(10)
      expect(metrics["tokens_input"]).to eq(5000)
      expect(metrics["tokens_output"]).to eq(2000)
      expect(metrics["cost_cents"]).to eq(75)
    end

    it "creates a system log entry for the violation" do
      expect {
        described_class.call(
          agent_run: agent_run,
          violation_type: "loop_detected",
          details: "5 consecutive identical outputs"
        )
      }.to change { agent_run.agent_run_logs.where(log_type: "system").count }.by(1)

      log = agent_run.agent_run_logs.where(log_type: "system").last
      expect(log.content).to include("loop_detected")
      expect(log.content).to include("5 consecutive identical outputs")
    end

    it "does not broadcast directly and enqueues the dashboard alert pipeline" do
      allow(Turbo::StreamsChannel).to receive(:broadcast_prepend_to)

      expect {
        described_class.call(
          agent_run: agent_run,
          violation_type: "cost_limit",
          details: "Budget exceeded"
        )
      }.to have_enqueued_job(LiveDashboardBroadcastJob).at_least(:once)

      expect(Turbo::StreamsChannel).not_to have_received(:broadcast_prepend_to)
    end

    it "records cleanup failure details in the stored context" do
      allow(AgentRuns::Cancel).to receive(:call).and_raise(StandardError, "Temporal RPC error")

      result = described_class.call(
        agent_run: agent_run,
        violation_type: "cost_limit",
        details: "Budget exceeded"
      )

      expect(result.paused?).to be true

      cleanup = agent_run.reload.guardrail_context["execution_cleanup"]
      expect(cleanup).to include(
        "status" => "cancel_failed",
        "error_class" => "StandardError",
        "error_message" => "Temporal RPC error"
      )
    end

    it "does not pause a non-running agent run" do
      agent_run.update!(status: "completed", completed_at: Time.current)

      result = described_class.call(
        agent_run: agent_run,
        violation_type: "loop_detected",
        details: "Repeated output"
      )

      expect(result.paused?).to be false
      expect(agent_run.reload.status).to eq("completed")
    end

    it "does not pause an already paused agent run" do
      agent_run.update!(status: "paused", paused_at: Time.current, guardrail_violation_type: "loop_detected")

      result = described_class.call(
        agent_run: agent_run,
        violation_type: "cost_limit",
        details: "Budget exceeded"
      )

      expect(result.paused?).to be true
      expect(result.violation_type).to eq("loop_detected")
      expect(agent_run.reload.guardrail_violation_type).to eq("loop_detected")
    end

    it "raises on unknown violation type" do
      expect {
        described_class.call(
          agent_run: agent_run,
          violation_type: "unknown",
          details: "Something weird"
        )
      }.to raise_error(ArgumentError, /Unknown violation type/)
    end
  end
end
