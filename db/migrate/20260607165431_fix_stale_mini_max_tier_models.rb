# frozen_string_literal: true

class FixStaleMiniMaxTierModels < ActiveRecord::Migration[8.1]
  STALE_MODEL = "MiniMax-M2.7"
  CORRECT_MODEL = "MiniMax-M3"

  # Runner/Provider pairs with stale tier_models pointing to MiniMax-M2.7
  AFFECTED_PAIRS = [
    { id: 27, label: "Pi MiniMax" },
    { id: 26, label: "Opencode MiniMax" }
  ].freeze

  def up
    AFFECTED_PAIRS.each do |pair|
      %w[runners providers].each do |table|
        fix_tier_models!(table, pair[:id], pair[:label])
      end
    end
  end

  def down
    # Intentionally no-op: reverting would restore broken model references
  end

  private

  def fix_tier_models!(table, id, label)
    safety_assured do
      return unless connection.table_exists?(table)

      record = execute("SELECT tier_models FROM #{table} WHERE id = #{id}").first
      return unless record

      tier_models = JSON.parse(record["tier_models"] || "{}")
      return unless tier_models.any? { |_, v| v.is_a?(Hash) && v["model_id"] == STALE_MODEL }

      new_tier_models = %w[low mid high].each_with_object({}) do |tier, h|
        h[tier] = { "model_id" => CORRECT_MODEL, "provider_id" => id }
      end

      execute(<<~SQL)
        UPDATE #{table}
        SET tier_models = '#{new_tier_models.to_json}',
            updated_at = NOW()
        WHERE id = #{id}
          AND tier_models::jsonb @> '{"mid": {"model_id": "#{STALE_MODEL}"}}'::jsonb
      SQL

      say "Fixed #{table}##{id} (#{label}): #{STALE_MODEL} → #{CORRECT_MODEL}"
    end
  end
end
