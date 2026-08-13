# frozen_string_literal: true

class AddSyntheticToAgentRuns < ActiveRecord::Migration[8.1] # @spec LIVE-PREVIEW-003
  def up
    add_synthetic_column
    backfill_preview_runs_as_synthetic
    repair_project_counter_caches_for_backfilled_preview_runs
  end

  def down
    remove_column :agent_runs, :synthetic, if_exists: true
  end

  private

  def add_synthetic_column
    return if column_exists?(:agent_runs, :synthetic)

    add_column :agent_runs, :synthetic, :boolean, default: false, null: false,
      comment: "Operational-only run that reuses the agent-run lifecycle to drive " \
               "infrastructure (e.g. live-preview provisioning) but never executes a real " \
               "agent or produces a PR/issue/review artifact. Excluded from user-facing run " \
               "history and totals. Keyed off this flag rather than agent_type because " \
               "internal_agent is shared with legitimate externally-ingested runs."
  end

  def backfill_preview_runs_as_synthetic
    # Backfill the existing preview-provisioning runs that, before this column,
    # were tagged only via the preview-specific marker in
    # external_metadata['preview_session'] (set by Previews::Lifecycle on main).
    # Backfilling off that marker — not off agent_type + execution_origin —
    # ensures only genuine preview runs are marked synthetic, leaving any other
    # native internal_agent history (e.g. externally-ingested runs) intact.
    safety_assured do
      execute <<~SQL.squish
        UPDATE agent_runs
        SET synthetic = true
        WHERE external_metadata @> '{"preview_session": true}'::jsonb
      SQL
    end
  end

  def repair_project_counter_caches_for_backfilled_preview_runs
    safety_assured do
      execute <<~SQL.squish
        WITH affected_projects AS (
          SELECT DISTINCT project_id
          FROM agent_runs
          WHERE external_metadata @> '{"preview_session": true}'::jsonb
            AND project_id IS NOT NULL
        ),
        corrected_counts AS (
          SELECT
            affected_projects.project_id,
            COUNT(agent_runs.id) FILTER (WHERE agent_runs.synthetic = false) AS agent_runs_count,
            COUNT(agent_runs.id) FILTER (
              WHERE agent_runs.synthetic = false
                AND agent_runs.status = 'completed'
            ) AS completed_agent_runs_count
          FROM affected_projects
          LEFT JOIN agent_runs ON agent_runs.project_id = affected_projects.project_id
          GROUP BY affected_projects.project_id
        )
        UPDATE projects
        SET agent_runs_count = corrected_counts.agent_runs_count,
            completed_agent_runs_count = corrected_counts.completed_agent_runs_count
        FROM corrected_counts
        WHERE projects.id = corrected_counts.project_id
      SQL
    end
  end
end
