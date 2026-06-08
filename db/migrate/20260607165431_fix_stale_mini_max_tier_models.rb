# frozen_string_literal: true

# Some runners have a stale tier_models entry pointing to MiniMax-M2.7
# while their config already specifies MiniMax-M3.  ResolveTierModel
# checks tier_models first, so the stale value takes precedence.
# This migration replaces MiniMax-M2.7 with MiniMax-M3 in tier_models
# for every affected row, identified by data rather than fixed IDs.
class FixStaleMiniMaxTierModels < ActiveRecord::Migration[8.1]
  STALE_MODEL = "MiniMax-M2.7"
  CORRECT_MODEL = "MiniMax-M3"

  def up
    safety_assured do
      rows = execute(<<~SQL)
        SELECT id FROM runners
        WHERE tier_models::jsonb @> '{"mid": {"model_id": "#{STALE_MODEL}"}}'::jsonb
      SQL

      rows.each do |row|
        id = row["id"]
        new_tier_models = %w[low mid high].each_with_object({}) do |tier, h|
          h[tier] = { "model_id" => CORRECT_MODEL, "provider_id" => id }
        end

        execute(<<~SQL)
          UPDATE runners
          SET tier_models = '#{new_tier_models.to_json}',
              updated_at = NOW()
          WHERE id = #{id}
            AND tier_models::jsonb @> '{"mid": {"model_id": "#{STALE_MODEL}"}}'::jsonb
        SQL

        say "Fixed runners##{id}: #{STALE_MODEL} → #{CORRECT_MODEL}"
      end
    end
  end

  def down
    # Intentionally no-op: reverting would restore broken model references
  end
end
