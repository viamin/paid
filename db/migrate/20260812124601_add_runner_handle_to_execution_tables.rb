# frozen_string_literal: true

# Adds a provider-neutral +runner_handle+ jsonb column alongside the existing
# Docker-specific container reference columns. The handle stores everything
# needed to reconnect to a remotely running workload after a worker restart or
# failover, without exposing Docker IDs to higher-level code (RDR-054).
#
# During migration, existing rows that carry a +container_id+ are backfilled
# with a +runner_handle+ derived from their Docker reference so the runner-level
# recovery path can observe or clean them up immediately.
class AddRunnerHandleToExecutionTables < ActiveRecord::Migration[8.1]
  def up
    add_column :agent_runs, :runner_handle, :jsonb,
      comment: "Persisted ExecutionRunners::RunnerHandle for recovery after " \
               "worker restart/failover (RDR-054). Populated from container_id " \
               "during migration; stored alongside (not replacing) container_id." \
      unless column_exists?(:agent_runs, :runner_handle)
    add_column :container_pool_entries, :runner_handle, :jsonb,
      comment: "Persisted ExecutionRunners::RunnerHandle for warm-pool entries " \
               "(RDR-054). Stored alongside container_id/workspace_volume." \
      unless column_exists?(:container_pool_entries, :runner_handle)
    add_column :service_containers, :runner_handle, :jsonb,
      comment: "Persisted ExecutionRunners::RunnerHandle for service containers " \
               "(RDR-054). Stored alongside docker_container_id." \
      unless column_exists?(:service_containers, :runner_handle)

    backfill_agent_run_handles
  end

  def down
    remove_column :service_containers, :runner_handle if column_exists?(:service_containers, :runner_handle)
    remove_column :container_pool_entries, :runner_handle if column_exists?(:container_pool_entries, :runner_handle)
    remove_column :agent_runs, :runner_handle if column_exists?(:agent_runs, :runner_handle)
  end

  private

  # Backfills agent_runs.runner_handle from existing container_id + container_host
  # so the runner-level recovery path can observe or clean up containers that
  # were provisioned before the runner_handle column existed.
  def backfill_agent_run_handles
    run_class = Class.new(ActiveRecord::Base) do
      self.table_name = "agent_runs"
    end
    run_class.reset_column_information

    run_class.where.not(container_id: nil).find_each do |run|
      handle = {
        "runner_type" => "local_docker",
        "identifier" => run.container_id,
        "host" => run.container_host,
        "workspace_ref" => "paid-workspace-#{run.id}",
        "metadata" => {}
      }
      run_class.where(id: run.id).update_all(runner_handle: handle)
    end
  end
end
