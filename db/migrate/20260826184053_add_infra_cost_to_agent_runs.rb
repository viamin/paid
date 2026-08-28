# frozen_string_literal: true

# @spec EXEC-USAGE-002
class AddInfraCostToAgentRuns < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:agent_runs)

    unless column_exists?(:agent_runs, :runner_backend)
      add_column :agent_runs, :runner_backend, :string, limit: 64,
        comment: "Execution runner/backend key copied from the run's ExecutionUsage for cheap aggregation. Mirrors the per-host rate key (e.g. local, fly_machine)."
    end

    unless column_exists?(:agent_runs, :infra_cost_cents)
      add_column :agent_runs, :infra_cost_cents, :integer, default: 0, null: false,
        comment: "Estimated (or provider-reported) infrastructure cost for the run. Mirrors ExecutionUsage#infra_cost_cents so per-run queries avoid joining the usage table."
    end

    unless column_exists?(:agent_runs, :billed_duration_seconds)
      add_column :agent_runs, :billed_duration_seconds, :integer, default: 0, null: false,
        comment: "Cloud-billed lifetime of the run's resource (provisioned_at → terminated_at). Mirrors ExecutionUsage#billed_duration_seconds."
    end
  end

  def down
    return unless table_exists?(:agent_runs)

    if column_exists?(:agent_runs, :billed_duration_seconds)
      remove_column :agent_runs, :billed_duration_seconds
    end

    if column_exists?(:agent_runs, :infra_cost_cents)
      remove_column :agent_runs, :infra_cost_cents
    end

    if column_exists?(:agent_runs, :runner_backend)
      remove_column :agent_runs, :runner_backend
    end
  end
end
