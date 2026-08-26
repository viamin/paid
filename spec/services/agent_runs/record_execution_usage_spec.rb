# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::RecordExecutionUsage do
  let(:agent_run) { create(:agent_run, :completed) }
  # Fixed offsets from a single reference instant so billed_duration_seconds is
  # exactly 1800 rather than whatever two separate Time.current calls truncate to.
  let(:provisioned_at) { 1.hour.ago.change(usec: 0) }
  let(:terminated_at) { provisioned_at + 30.minutes }
  let(:rate_60_per_hour) { { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "60" } }

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

    # @spec EXEC-USAGE-011
    it "preserves the first recorded termination when a delayed pass re-records" do
      record_usage(env: rate_60_per_hour, agent_run: agent_run)
      first = agent_run.reload.execution_usage

      record_usage(env: rate_60_per_hour, agent_run: agent_run, termination_reason: "cancelled",
        terminated_at: terminated_at + 30.minutes)

      expect(ExecutionUsage.where(agent_run_id: agent_run.id).count).to eq(1)
      usage = agent_run.reload.execution_usage
      expect(usage.id).to eq(first.id)
      expect(usage.terminated_at).to eq(terminated_at)
      expect(usage.billed_duration_seconds).to eq(1800)
      expect(usage.infra_cost_cents).to eq(30)
      expect(usage.termination_reason).to eq("completed")
    end

    # @spec EXEC-USAGE-011
    it "does not inflate the denormalized run columns on a delayed re-record" do
      record_usage(env: rate_60_per_hour, agent_run: agent_run)

      record_usage(env: rate_60_per_hour, agent_run: agent_run, terminated_at: terminated_at + 30.minutes)

      agent_run.reload
      expect(agent_run.billed_duration_seconds).to eq(1800)
      expect(agent_run.infra_cost_cents).to eq(30)
    end

    # @spec EXEC-USAGE-011
    it "returns the preserved row's cost instead of the re-priced estimate" do
      record_usage(env: rate_60_per_hour, agent_run: agent_run)

      result = record_usage(env: rate_60_per_hour, agent_run: agent_run, terminated_at: terminated_at + 30.minutes)

      expect(result[:usage]).to eq(agent_run.reload.execution_usage)
      expect(result[:infra_cost_cents]).to eq(30)
      expect(result[:rate_cents_per_hour]).to eq(60)
    end

    # @spec EXEC-USAGE-011
    it "mirrors an existing row onto a run whose denormalized columns were never stamped" do
      usage = create(:execution_usage, agent_run: agent_run, runner_backend: "local",
        billed_duration_seconds: 600, infra_cost_cents: 25, rate_cents_per_hour: 150)
      agent_run.update_columns(runner_backend: nil, billed_duration_seconds: 0, infra_cost_cents: 0)

      record_usage(env: rate_60_per_hour, agent_run: agent_run)

      agent_run.reload
      expect(agent_run.runner_backend).to eq("local")
      expect(agent_run.billed_duration_seconds).to eq(usage.billed_duration_seconds)
      expect(agent_run.infra_cost_cents).to eq(usage.infra_cost_cents)
    end

    it "returns nil and logs a warning when required inputs are missing" do
      result = described_class.call(
        agent_run: agent_run,
        runner_backend: nil,
        provisioned_at: provisioned_at,
        terminated_at: terminated_at,
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
        provisioned_at: terminated_at,
        terminated_at: provisioned_at,
        termination_reason: "completed"
      )

      expect(result).to be_nil
      expect(Rails.logger).to have_received(:warn).with(
        hash_including(message: "agent_execution.record_execution_usage_failed",
                       reason: "terminated_at must be on or after provisioned_at")
      )
    end
  end

  def record_usage(env:, agent_run:, termination_reason: "completed", terminated_at: nil)
    described_class.call(
      agent_run: agent_run,
      runner_backend: "local",
      provider_resource_id: "fly-machine-abc",
      provisioned_at: provisioned_at,
      completed_at: provisioned_at + 30.minutes,
      terminated_at: terminated_at || self.terminated_at,
      termination_reason: termination_reason,
      requested_cpu_cores: BigDecimal("2.0"),
      requested_memory_mib: 4096,
      requested_disk_gb: 40,
      env: env
    )
  end
end
