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

    # Backfill existing preview-provisioning runs. A synthetic preview run is created
    # natively (execution_origin defaults to "paid_native") and never via external
    # ingestion, which always sets execution_origin to "external". This is the
    # preview-specific signal that distinguishes synthetic operational runs from
    # legitimate imported internal_agent runs (internal_agent_workflows source).
    safety_assured do
      execute <<~SQL.squish
        UPDATE agent_runs
        SET synthetic = true
        WHERE agent_type = 'internal_agent'
          AND COALESCE(execution_origin, 'paid_native') <> 'external'
      SQL
    end
  end

  def down
    remove_column :agent_runs, :synthetic, if_exists: true
  end
end
