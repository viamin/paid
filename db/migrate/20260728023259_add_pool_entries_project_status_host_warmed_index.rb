# frozen_string_literal: true

class AddPoolEntriesProjectStatusHostWarmedIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # RDR-048 (#2947): host-scoped pool queries (cleanup_claimed_finished_runs,
  # stale_warm_pool_entries, stale_warming, current_pool_entries) all filter by
  # project_id, status, and container_host. The pre-existing
  # (project_id, status, warmed_at) index cannot satisfy the new container_host
  # predicate, so each query degrades to a Ruby-side filter on a larger result
  # set as the pool grows across multiple hosts. Adding container_host into the
  # leading key list keeps the index usable for the existing single-host path
  # and adds it for the multi-host path.
  #
  # Limited to three columns by strong_migrations' best-practice check. warmed_at
  # ordering happens after filtering via .order(:warmed_at, :id), which the
  # planner can still satisfy via an in-memory sort over the small per-project
  # result set the new index returns.
  #
  # Built CONCURRENTLY to avoid blocking writes against the warm-pool tables
  # during deployment, per strong_migrations' guidance.
  def change
    return if index_exists?(:container_pool_entries,
      [ :project_id, :container_host, :status ],
      name: "idx_pool_entries_project_host_status")

    add_index :container_pool_entries,
      [ :project_id, :container_host, :status ],
      name: "idx_pool_entries_project_host_status",
      algorithm: :concurrently
  end
end
