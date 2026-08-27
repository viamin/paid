# frozen_string_literal: true

require "rails_helper"

RSpec.describe AgentRuns::RecordExecutionUsage do
  let(:agent_run) do
    create(:agent_run, :completed, external_metadata: {
      "infrastructure_spend" => { "rate_cents_per_hour" => 120 }
    })
  end
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
      expect(usage.infra_cost_cents).to eq(60)
      expect(usage.rate_cents_per_hour).to eq(120)
      expect(usage.requested_cpu_cores).to eq(BigDecimal("2.0"))
      expect(usage.requested_memory_mib).to eq(4096)
      expect(usage.requested_disk_gb).to eq(40)
      expect(usage.termination_reason).to eq("completed")
    end

    it "denormalizes the cost onto the AgentRun row" do
      record_usage(env: { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "999" }, agent_run: agent_run)

      agent_run.reload
      expect(agent_run.runner_backend).to eq("local")
      expect(agent_run.billed_duration_seconds).to eq(1800)
      expect(agent_run.infra_cost_cents).to eq(60)
    end

    it "uses the admission-time stamped rate instead of a newer env rate" do
      result = record_usage(env: { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "999" }, agent_run: agent_run)

      usage = agent_run.reload.execution_usage
      expect(usage.rate_cents_per_hour).to eq(120)
      expect(usage.infra_cost_cents).to eq(60)
      expect(result[:rate_cents_per_hour]).to eq(120)
      expect(result[:infra_cost_cents]).to eq(60)
    end

    # @spec EXEC-USAGE-011
    it "preserves the first recorded termination when a delayed pass re-records" do
      stamp_rate(agent_run, 60)
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
      stamp_rate(agent_run, 60)
      record_usage(env: rate_60_per_hour, agent_run: agent_run)

      record_usage(env: rate_60_per_hour, agent_run: agent_run, terminated_at: terminated_at + 30.minutes)

      agent_run.reload
      expect(agent_run.billed_duration_seconds).to eq(1800)
      expect(agent_run.infra_cost_cents).to eq(30)
    end

    # @spec EXEC-USAGE-011
    it "returns the preserved row's cost instead of the re-priced estimate" do
      stamp_rate(agent_run, 60)
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

    # @spec EXEC-USAGE-011
    it "replaces the row when the run was re-provisioned after the recorded termination" do
      first_usage, result = reprovisioned_usage(agent_run)
      usage = agent_run.reload.execution_usage

      expect(ExecutionUsage.where(agent_run_id: agent_run.id).ids).to eq([ usage.id ])
      expect(usage.id).not_to eq(first_usage.id)
      expect(usage.attributes.slice(*reprovisioned_usage_snapshot.keys)).to eq(reprovisioned_usage_snapshot)
      expect(result[:usage]).to eq(usage)
      expect(result.slice(:infra_cost_cents, :rate_cents_per_hour)).to eq(reprovisioned_result_snapshot)
      expect(agent_run.attributes.slice(*reprovisioned_run_snapshot.keys)).to eq(reprovisioned_run_snapshot)
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

  def stamp_rate(agent_run, rate_cents_per_hour)
    agent_run.update!(external_metadata: {
      "infrastructure_spend" => { "rate_cents_per_hour" => rate_cents_per_hour }
    })
  end

  def reprovisioned_usage(agent_run)
    stamp_rate(agent_run, 60)
    first_usage = record_usage(env: rate_60_per_hour, agent_run: agent_run, termination_reason: "evicted")[:usage]
    reprovisioned_at = first_usage.terminated_at + 5.minutes

    stamp_rate(agent_run, 120)
    result = record_usage(
      env: { "INFRA_SPEND_RATE_CENTS_PER_HOUR__LOCAL" => "999" },
      agent_run: agent_run,
      provider_resource_id: "fly-machine-def",
      provisioned_at: reprovisioned_at,
      completed_at: reprovisioned_at + 20.minutes,
      terminated_at: reprovisioned_at + 20.minutes,
      termination_reason: "completed"
    )

    [ first_usage, result ]
  end

  def reprovisioned_usage_snapshot
    {
      "provider_resource_id" => "fly-machine-def",
      "billed_duration_seconds" => 1200,
      "termination_reason" => "completed",
      "rate_cents_per_hour" => 120,
      "infra_cost_cents" => 40
    }
  end

  def reprovisioned_result_snapshot
    {
      infra_cost_cents: 40,
      rate_cents_per_hour: 120
    }
  end

  def reprovisioned_run_snapshot
    {
      "billed_duration_seconds" => 1200,
      "infra_cost_cents" => 40
    }
  end

  def record_usage(env:, agent_run:, provider_resource_id: "fly-machine-abc",
    provisioned_at: self.provisioned_at, completed_at: provisioned_at + 30.minutes,
    termination_reason: "completed", terminated_at: nil)
    described_class.call(
      agent_run: agent_run,
      runner_backend: "local",
      provider_resource_id: provider_resource_id,
      provisioned_at: provisioned_at,
      completed_at: completed_at,
      terminated_at: terminated_at || self.terminated_at,
      termination_reason: termination_reason,
      requested_cpu_cores: BigDecimal("2.0"),
      requested_memory_mib: 4096,
      requested_disk_gb: 40,
      env: env
    )
  end
end
