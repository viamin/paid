# frozen_string_literal: true

class ChangeActivePrRunIndexToIncludeGoal < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_pr", algorithm: :concurrently, if_exists: true

    add_index :agent_runs, [ :project_id, :source_pull_request_number, :goal ],
      unique: true,
      where: "source_pull_request_number IS NOT NULL AND status IN ('queued', 'pending', 'running', 'paused')",
      name: "idx_agent_runs_unique_active_pr",
      algorithm: :concurrently,
      if_not_exists: true
  end

  def down
    remove_index :agent_runs, name: "idx_agent_runs_unique_active_pr", algorithm: :concurrently, if_exists: true
    collapse_duplicate_active_pr_runs!

    add_index :agent_runs, [ :project_id, :source_pull_request_number ],
      unique: true,
      where: "source_pull_request_number IS NOT NULL AND status IN ('queued', 'pending', 'running', 'paused')",
      name: "idx_agent_runs_unique_active_pr",
      algorithm: :concurrently,
      if_not_exists: true
  end

  private

  def collapse_duplicate_active_pr_runs!
    execute <<~SQL.squish
      WITH ranked_duplicates AS (
        SELECT
          id,
          ROW_NUMBER() OVER (
            PARTITION BY project_id, source_pull_request_number
            ORDER BY created_at DESC, id DESC
          ) AS duplicate_rank
        FROM agent_runs
        WHERE source_pull_request_number IS NOT NULL
          AND status IN ('queued', 'pending', 'running', 'paused')
      )
      UPDATE agent_runs
      SET
        status = 'cancelled',
        completed_at = COALESCE(completed_at, CURRENT_TIMESTAMP),
        error_message = CONCAT(
          COALESCE(NULLIF(error_message, ''), ''),
          CASE WHEN COALESCE(NULLIF(error_message, ''), '') = '' THEN '' ELSE E'\\n' END,
          'Cancelled automatically while restoring the pre-goal PR uniqueness constraint.'
        ),
        updated_at = CURRENT_TIMESTAMP
      FROM ranked_duplicates
      WHERE agent_runs.id = ranked_duplicates.id
        AND ranked_duplicates.duplicate_rank > 1
    SQL
  end
end
