# frozen_string_literal: true

# Some runners have a stale tier_models.mid pointing to MiniMax-M2.7
# while their config already specifies MiniMax-M3.  ResolveTierModel
# checks tier_models first, so the stale value takes precedence.
#
# This migration uses jsonb_set to replace only the stale mid entry,
# preserving any non-stale low/high mappings.  It is scoped to rows
# whose direct-outbound config model is already MiniMax-M3 so it will
# not touch runners intentionally configured to use M2.7.
class FixStaleMiniMaxTierModels < ActiveRecord::Migration[8.1]
  STALE_MODEL = "MiniMax-M2.7"
  CORRECT_MODEL = "MiniMax-M3"

  def up
    safety_assured do
      # Only fix rows where:
      #   1. tier_models.mid.model_id is the stale MiniMax-M2.7
      #   2. the runner's direct-outbound config model is already the
      #      correct model (checked across known runner_key config paths)
      execute(<<~SQL)
        UPDATE runners
        SET tier_models = jsonb_set(
              tier_models,
              '{mid,model_id}',
              '"#{CORRECT_MODEL}"'
            ),
            updated_at = NOW()
        WHERE tier_models::jsonb @> '{"mid": {"model_id": "#{STALE_MODEL}"}}'::jsonb
          AND (
            config->'pi'->>'model' = '#{CORRECT_MODEL}'
            OR config->'opencode'->>'model' = '#{CORRECT_MODEL}'
            OR config->'kilocode'->>'model' = '#{CORRECT_MODEL}'
          )
      SQL
    end
  end

  def down
    # Intentionally no-op: reverting would restore broken model references
  end
end
