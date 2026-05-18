# frozen_string_literal: true

class BackfillRunnersAttemptedLegacyProviderKey < ActiveRecord::Migration[8.1]
  def up
    safety_assured do
      execute <<~SQL.squish
      UPDATE agent_runs
      SET runners_attempted = (
        SELECT jsonb_agg(
          CASE WHEN entry ? 'provider' AND NOT (entry ? 'runner')
               THEN (entry - 'provider') || jsonb_build_object('runner', entry->'provider')
               ELSE entry
          END
        )
        FROM jsonb_array_elements(runners_attempted) AS entry
      )
      WHERE runners_attempted IS NOT NULL
        AND runners_attempted::text LIKE '%"provider"%'
      SQL
    end
  end

  def down
    # No-op: the old "provider" key was unintentional data drift, not a
    # deliberate schema choice. Rolling back the migration would
    # reintroduce silent nil reads in three call sites.
  end
end
