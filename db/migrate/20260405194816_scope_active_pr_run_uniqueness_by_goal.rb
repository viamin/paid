# frozen_string_literal: true

class ScopeActivePrRunUniquenessByGoal < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ACTIVE_PR_RUN_WHERE = "source_pull_request_number IS NOT NULL AND status IN ('queued', 'pending', 'running', 'paused')"

  def up
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_pr", algorithm: :concurrently, if_exists: true

    add_index :agent_runs, [ :project_id, :source_pull_request_number, :goal ],
      unique: true,
      where: ACTIVE_PR_RUN_WHERE,
      name: "idx_agent_runs_unique_active_pr",
      algorithm: :concurrently
  end

  def down
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_pr", algorithm: :concurrently, if_exists: true

    # Restore the old per-PR uniqueness constraint only when it is safe to do so.
    # After the up migration runs, the same PR can have concurrent active runs for
    # different goals (e.g. a create_pr run alongside a review run). Attempting to
    # add a unique index on (project_id, source_pull_request_number) while such rows
    # exist would fail and block the rollback path. Skip the restore in that case.
    conflict_exists = connection.select_value(<<~SQL.squish)
      SELECT 1 FROM agent_runs
      WHERE #{ACTIVE_PR_RUN_WHERE}
      GROUP BY project_id, source_pull_request_number
      HAVING COUNT(*) > 1
      LIMIT 1
    SQL

    return if conflict_exists

    add_index :agent_runs, [ :project_id, :source_pull_request_number ],
      unique: true,
      where: ACTIVE_PR_RUN_WHERE,
      name: "idx_agent_runs_unique_active_pr",
      algorithm: :concurrently
  end
end
