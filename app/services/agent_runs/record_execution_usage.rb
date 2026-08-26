# frozen_string_literal: true

# Records the per-run infrastructure usage summary onto the
# +AgentRun+ and creates its +ExecutionUsage+ row at
# termination. The cost is estimated via +ExecutionUsageCostEstimator+
# from the run's host-keyed rate and the provider-billed lifetime, so
# runs that never reached provisioning never produce an
# +ExecutionUsage+ row and contribute zero infra cost.
#
# Recording is first-write-wins: the fallback cleanup paths
# (+AgentRunResourceJanitorJob+, +AgentRuns::CleanupStale+) re-enter this
# service after +AgentRun#cleanup_container+ may already have closed the run
# out, so the earliest recorded termination is the one the resource actually
# had. See +recorded_usage+.
class AgentRuns::RecordExecutionUsage
  DENORMALIZED_AGENT_RUN_COLUMNS = %i[runner_backend billed_duration_seconds infra_cost_cents].freeze

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

    usage = recorded_usage
    denormalize_onto_agent_run(usage)

    { usage: usage, infra_cost_cents: usage.infra_cost_cents, rate_cents_per_hour: usage.rate_cents_per_hour }
  end

  private

  # The billed lifetime is frozen at the first recorded termination. A later
  # cleanup pass tears nothing down — the janitor counts an already-absent
  # volume as cleaned — so re-pricing the row against its +Time.current+
  # would overstate spend for a resource that was only released once.
  # @spec EXEC-USAGE-011
  def recorded_usage
    usage = ExecutionUsage.create_or_find_by!(agent_run_id: agent_run.id) do |record|
      record.assign_attributes(execution_usage_attributes)
    end
    log_preserved_recording(usage) unless usage.previously_new_record?
    usage
  end

  def execution_usage_attributes
    estimate = cost_estimate
    {
      runner_backend: runner_backend,
      provider_resource_id: provider_resource_id,
      provisioned_at: provisioned_at,
      execution_started_at: execution_started_at,
      completed_at: completed_at,
      terminated_at: terminated_at,
      billed_duration_seconds: billed_duration_seconds,
      requested_cpu_cores: requested_cpu_cores,
      requested_memory_mib: requested_memory_mib,
      requested_disk_gb: requested_disk_gb,
      termination_reason: termination_reason,
      infra_cost_cents: estimate.infra_cost_cents,
      rate_cents_per_hour: estimate.rate_cents_per_hour
    }
  end

  def billed_duration_seconds
    (terminated_at - provisioned_at).to_i
  end

  def cost_estimate
    ExecutionUsageCostEstimator.call(
      billed_duration_seconds: billed_duration_seconds,
      runner_backend: runner_backend,
      env: env
    )
  end

  # Mirrors the persisted row — never the estimate just computed — so the run's
  # denormalized columns always equal the recorded spend, and a run whose column
  # write was lost after the row was inserted self-heals on the next pass.
  # @spec EXEC-USAGE-002
  # @spec EXEC-USAGE-011
  def denormalize_onto_agent_run(usage)
    columns = DENORMALIZED_AGENT_RUN_COLUMNS.index_with { |column| usage.public_send(column) }
    return if columns.all? { |column, value| agent_run.public_send(column) == value }

    agent_run.update_columns(**columns, updated_at: Time.current)
  end

  def log_preserved_recording(usage)
    Rails.logger.debug(
      message: "agent_execution.execution_usage_already_recorded",
      agent_run_id: agent_run.id,
      execution_usage_id: usage.id,
      recorded_billed_duration_seconds: usage.billed_duration_seconds,
      skipped_billed_duration_seconds: billed_duration_seconds
    )
  end

  def failure(message)
    Rails.logger.warn(
      message: "agent_execution.record_execution_usage_failed",
      agent_run_id: agent_run&.id,
      reason: message
    )
    nil
  end
end
