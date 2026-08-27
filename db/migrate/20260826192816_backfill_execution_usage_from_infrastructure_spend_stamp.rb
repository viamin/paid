# frozen_string_literal: true

# @spec EXEC-USAGE-010
# One-time bridge for the transition described in
# docs/intent/execution-usage-and-cost-accounting/execution-usage-and-cost-accounting-design.md:
# runs provisioned before ExecutionUsage existed only have their infra rate
# stamped in external_metadata["infrastructure_spend"] (written by
# ProcessRunQueueJob#record_provisioning_start!) and were counted by
# Capacity::InfrastructureSpend's admission-time SQL. Without this backfill,
# switching Projects::CostDashboardStats to
# SUM(execution_usages.infra_cost_cents) would silently drop their infra cost
# to zero. Uses the stamped rate (not a re-resolved current-env rate) so the
# backfilled totals match what Capacity::InfrastructureSpend already reported
# for the same runs.
#
# Runs whose environment is still live — the container is currently retained
# (unexpired container_retained_until) or its ExecutionResource environment is
# active/cleanup_pending — are skipped: their billable lifetime is still open,
# so they keep accruing via the rowless (pending) spend path until the real
# teardown records the actual terminated_at. Freezing them at completed_at now
# would undercount them, and RecordExecutionUsage's first-write-wins semantics
# would preserve the short backfilled row over the later true termination.
class BackfillExecutionUsageFromInfrastructureSpendStamp < ActiveRecord::Migration[8.1]
  class MigrationAgentRun < ApplicationRecord
    self.table_name = "agent_runs"
  end

  class MigrationExecutionUsage < ApplicationRecord
    self.table_name = "execution_usages"
  end

  TERMINATION_REASON_BY_STATUS = {
    "completed" => "completed",
    "no_output" => "completed",
    "cancelled" => "cancelled",
    "timeout" => "timed_out",
    "failed" => "failed",
    "token_budget_exceeded" => "failed",
    "auth_expired" => "failed"
  }.freeze

  def up
    return unless table_exists?(:execution_usages) && column_exists?(:agent_runs, :provisioning_started_at)

    candidate_ids.each_slice(500) { |batch_ids| backfill_batch(batch_ids) }
  end

  def down
    # Backfilled rows are indistinguishable from normally-recorded ExecutionUsage
    # rows once written (the recorder uses the same find_or_initialize_by
    # upsert semantics), so there is nothing safe to revert here.
  end

  private

  def candidate_ids
    with_tenant_bypass { candidates.pluck(:id) }
  end

  def candidates
    scope = MigrationAgentRun
      .where.not(provisioning_started_at: nil)
      .where.not(completed_at: nil)
      .where("completed_at >= provisioning_started_at")
      .where("external_metadata #>> '{infrastructure_spend,rate_cents_per_hour}' IS NOT NULL")
      .where("id NOT IN (SELECT agent_run_id FROM execution_usages)")
      .where("container_retained_until IS NULL OR container_retained_until <= ?", Time.current)

    scope = scope.where(live_environment_exclusion_sql) if table_exists?(:execution_resources)
    scope
  end

  # Runs whose environment resource is still active or awaiting cleanup keep
  # accruing through the rowless (pending) spend path until the real teardown
  # records their termination; backfilling them now would freeze their billable
  # lifetime at completed_at, and the recorder's first-write-wins semantics
  # would then preserve that short row over the true termination.
  def live_environment_exclusion_sql
    <<~SQL.squish
      NOT EXISTS (
        SELECT 1 FROM execution_resources
        WHERE execution_resources.agent_run_id = agent_runs.id
          AND execution_resources.resource_type = 'environment'
          AND execution_resources.state IN ('active', 'cleanup_pending')
      )
    SQL
  end

  def backfill_batch(batch_ids)
    with_tenant_bypass do
      rows = migration_agent_runs_for(batch_ids).filter_map { |agent_run| execution_usage_attributes_for(agent_run) }
      next if rows.empty?

      MigrationExecutionUsage.insert_all(rows, unique_by: :agent_run_id)
      backfill_agent_run_columns!(rows)
    end
  end

  def execution_usage_attributes_for(agent_run)
    rate = agent_run.external_metadata.dig("infrastructure_spend", "rate_cents_per_hour").to_i
    return if rate <= 0

    billed_duration = (agent_run.completed_at - agent_run.provisioning_started_at).to_i
    return if billed_duration.negative?

    now = Time.current
    resources = agent_run.external_metadata["requested_resources"] || {}

    {
      agent_run_id: agent_run.id,
      runner_backend: backend_for(agent_run),
      provisioned_at: agent_run.provisioning_started_at,
      execution_started_at: agent_run.started_at,
      completed_at: agent_run.completed_at,
      terminated_at: agent_run.completed_at,
      billed_duration_seconds: billed_duration,
      requested_cpu_cores: requested_cpu_cores(resources),
      requested_memory_mib: requested_memory_mib(resources),
      requested_disk_gb: requested_disk_gb(resources),
      termination_reason: TERMINATION_REASON_BY_STATUS.fetch(agent_run.status, "evicted"),
      infra_cost_cents: ((rate.to_f * billed_duration) / 3600.0).round,
      rate_cents_per_hour: rate,
      created_at: now,
      updated_at: now
    }
  end

  # Docker CPU quota is expressed in units where 100_000 = 1 CPU core
  # (Containers::Provision's CpuPeriod) — convert back to cores.
  def requested_cpu_cores(resources)
    resources["cpu_quota"].to_f / 100_000.0
  end

  def requested_memory_mib(resources)
    (resources["memory_bytes"].to_f / 1.megabyte).round
  end

  def requested_disk_gb(resources)
    (resources["disk_bytes"].to_f / 1.gigabyte).round
  end

  # planned_container_host is the host record_provisioning_start! actually
  # resolved the stamped rate against (see ProcessRunQueueJob); container_host
  # itself is cleared by AgentRun#clear_container_id_if_unchanged! once
  # cleanup completes, so it is rarely still present on a finished run.
  def backend_for(agent_run)
    (agent_run.external_metadata["planned_container_host"].presence ||
      agent_run.container_host.presence ||
      "local").to_s.truncate(64)
  end

  def backfill_agent_run_columns!(rows)
    rows.each do |row|
      MigrationAgentRun.where(id: row[:agent_run_id]).update_all(
        runner_backend: row[:runner_backend],
        infra_cost_cents: row[:infra_cost_cents],
        billed_duration_seconds: row[:billed_duration_seconds]
      )
    end
  end

  def migration_agent_runs_for(batch_ids)
    MigrationAgentRun
      .select(:id, :status, :container_host, :provisioning_started_at,
        :started_at, :completed_at, :external_metadata)
      .find(batch_ids)
  end

  def with_tenant_bypass(&)
    # Wrapped explicitly (rather than relying on the Migrator's own
    # transaction) so `SET LOCAL` has a transaction to scope to whether this
    # runs via `db:migrate` or a spec calling `migrate(:up)` directly.
    ActiveRecord::Base.transaction do
      safety_assured { execute("SET LOCAL paid.bypass_tenant_rls = 'true'") }
      yield
    end
  end
end
