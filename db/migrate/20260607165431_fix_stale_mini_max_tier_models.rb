# frozen_string_literal: true

# Runner and Provider are both backed by the "runners" table.
# Rows 26 (Opencode MiniMax) and 27 (Pi MiniMax) have a stale
# tier_models entry pointing to MiniMax-M2.7 instead of MiniMax-M3.
class FixStaleMiniMaxTierModels < ActiveRecord::Migration[8.1]
  STALE_MODEL = "MiniMax-M2.7"
  CORRECT_MODEL = "MiniMax-M3"
  AFFECTED_IDS = [26, 27].freeze

  def up
    safety_assured do
      AFFECTED_IDS.each do |id|
        record = execute("SELECT tier_models FROM runners WHERE id = #{id}").first
        next unless record

        tier_models = JSON.parse(record["tier_models"] || "{}")
        next unless tier_models.any? { |_, v| v.is_a?(Hash) && v["model_id"] == STALE_MODEL }

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
