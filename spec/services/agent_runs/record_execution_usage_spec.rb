# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::RecordExecutionUsage do
  let(:agent_run) { create(:agent_run, :completed) }

  before { allow(Rails.logger).to receive(:warn) }

  describe ".call" do
    it "creates an ExecutionUsage row stamped with the estimated cost" do
      record_usage(env: { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "240" }, agent_run: agent_run)

      usage = agent_run.reload.execution_usage
      expect(usage).to be_present
      expect(usage.runner_backend).to eq("local")
      expect(usage.provider_resource_id).to eq("fly-machine-abc")
      expect(usage.billed_duration_seconds).to eq(1800)
      expect(usage.infra_cost_cents).to eq(120)
      expect(usage.rate_cents_per_hour).to eq(240)
      expect(usage.requested_cpu_cores).to eq(BigDecimal("2.0"))
      expect(usage.requested_memory_mib).to eq(4096)
      expect(usage.requested_disk_gb).to eq(40)
      expect(usage.termination_reason).to eq("completed")
    end

    it "denormalizes the cost onto the AgentRun row" do
      record_usage(env: { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "120" }, agent_run: agent_run)

      agent_run.reload
      expect(agent_run.runner_backend).to eq("local")
      expect(agent_run.billed_duration_seconds).to eq(1800)
      expect(agent_run.infra_cost_cents).to eq(60)
    end

    it "is idempotent — re-recording updates the existing row" do
      record_usage(env: { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "60" }, agent_run: agent_run)
      first_id = agent_run.reload.execution_usage.id

      record_usage(env: { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "60" }, agent_run: agent_run,
        termination_reason: "cancelled")

      expect(ExecutionUsage.where(agent_run_id: agent_run.id).count).to eq(1)
      usage = agent_run.reload.execution_usage
      expect(usage.id).to eq(first_id)
      expect(usage.termination_reason).to eq("cancelled")
    end

    it "returns nil and logs a warning when required inputs are missing" do
      result = described_class.call(
        agent_run: agent_run,
        runner_backend: nil,
        provisioned_at: 1.hour.ago,
        terminated_at: 30.minutes.ago,
        termination_reason: "completed"
      )

      expect(result).to be_nil
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "agent_execution.record_execution_usage_failed", reason: "runner_backend is required")
      )
    end

    it "returns nil and logs a warning when terminated_at precedes provisioned_at" do
      result = described_class.call(
        agent_run: agent_run,
        runner_backend: "local",
        provisioned_at: 30.minutes.ago,
        terminated_at: 1.hour.ago,
        termination_reason: "completed"
      )

      expect(result).to be_nil
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "agent_execution.record_execution_usage_failed",
                       reason: "terminated_at must be on or after provisioned_at")
      )
    end
  end

  def record_usage(env:, agent_run:, termination_reason: "completed")
    described_class.call(
      agent_run: agent_run,
      runner_backend: "local",
      provider_resource_id: "fly-machine-abc",
      provisioned_at: 1.hour.ago,
      completed_at: 30.minutes.ago,
      terminated_at: 30.minutes.ago,
      termination_reason: termination_reason,
      requested_cpu_cores: BigDecimal("2.0"),
      requested_memory_mib: 4096,
      requested_disk_gb: 40,
      env: env
    )
  end
end
