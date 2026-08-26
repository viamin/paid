# frozen_string_literal: true

# Records the per-run infrastructure usage summary onto the
# +AgentRun+ and creates (or updates) its +ExecutionUsage+ row at
# termination. The cost is estimated via +ExecutionUsage::CostEstimator+
# from the run's host-keyed rate and the provider-billed lifetime, so
# runs that never reached provisioning never produce an
# +ExecutionUsage+ row and contribute zero infra cost.
class AgentRuns::RecordExecutionUsage
  attr_reader :agent_run, :runner_backend, :provider_resource_id,
    :provisioned_at, :execution_started_at, :completed_at,
    :terminated_at, :requested_cpu_cores, :requested_memory_mib,
    :requested_disk_gb, :termination_reason, :env

  def self.call(...)
    new(...).call
  end

  def initialize(agent_run:, runner_backend:, provider_resource_id: nil,
    provisioned_at:, execution_started_at: nil, completed_at: nil,
    terminated_at:, requested_cpu_cores: nil, requested_memory_mib: nil,
    requested_disk_gb: nil, termination_reason:, env: ENV)
    @agent_run = agent_run
    @runner_backend = runner_backend
    @provider_resource_id = provider_resource_id
    @provisioned_at = provisioned_at
    @execution_started_at = execution_started_at
    @completed_at = completed_at
    @terminated_at = terminated_at
    @requested_cpu_cores = requested_cpu_cores
    @requested_memory_mib = requested_memory_mib
    @requested_disk_gb = requested_disk_gb
    @termination_reason = termination_reason
    @env = env
  end

  def call
    return failure("agent_run is required") if agent_run.blank?
    return failure("provisioned_at is required") if provisioned_at.blank?
    return failure("terminated_at is required") if terminated_at.blank?
    return failure("runner_backend is required") if runner_backend.blank?
    return failure("termination_reason is required") if termination_reason.blank?
    return failure("terminated_at must be on or after provisioned_at") if terminated_at < provisioned_at

    billed = (terminated_at - provisioned_at).to_i
    estimate = ExecutionUsageCostEstimator.call(
      billed_duration_seconds: billed,
      runner_backend: runner_backend,
      env: env
    )

    usage = ExecutionUsage.find_or_initialize_by(agent_run_id: agent_run.id)
    usage.assign_attributes(
      runner_backend: runner_backend,
      provider_resource_id: provider_resource_id,
      provisioned_at: provisioned_at,
      execution_started_at: execution_started_at,
      completed_at: completed_at,
      terminated_at: terminated_at,
      billed_duration_seconds: billed,
      requested_cpu_cores: requested_cpu_cores,
      requested_memory_mib: requested_memory_mib,
      requested_disk_gb: requested_disk_gb,
      termination_reason: termination_reason,
      infra_cost_cents: estimate.infra_cost_cents,
      rate_cents_per_hour: estimate.rate_cents_per_hour
    )
    usage.save!

    agent_run.update_columns(
      runner_backend: runner_backend,
      billed_duration_seconds: billed,
      infra_cost_cents: estimate.infra_cost_cents,
      updated_at: Time.current
    )

    { usage: usage, infra_cost_cents: estimate.infra_cost_cents, rate_cents_per_hour: estimate.rate_cents_per_hour }
  end

  private

  def failure(message)
    Rails.logger.warn(
      message: "agent_execution.record_execution_usage_failed",
      agent_run_id: agent_run&.id,
      reason: message
    )
    nil
  end
end
