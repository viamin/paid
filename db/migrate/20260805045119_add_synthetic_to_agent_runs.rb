# frozen_string_literal: true

class AddSyntheticToAgentRuns < ActiveRecord::Migration[8.1]
  def up
    return if column_exists?(:agent_runs, :synthetic)

    add_column :agent_runs, :synthetic, :boolean, default: false, null: false,
      comment: "Operational-only run that reuses the agent-run lifecycle to drive " \
               "infrastructure (e.g. live-preview provisioning) but never executes a real " \
               "agent or produces a PR/issue/review artifact. Excluded from user-facing run " \
               "history and totals. Keyed off this flag rather than agent_type because " \
               "internal_agent is shared with legitimate externally-ingested runs."

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

  def down
    remove_column :agent_runs, :synthetic, if_exists: true
  end
end
