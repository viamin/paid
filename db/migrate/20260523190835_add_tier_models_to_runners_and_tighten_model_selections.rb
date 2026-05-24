# frozen_string_literal: true

class AddTierModelsToRunnersAndTightenModelSelections < ActiveRecord::Migration[8.1]
  class MigrationRunner < ActiveRecord::Base
    self.table_name = "runners"
  end

  class MigrationModelSelection < ActiveRecord::Base
    self.table_name = "model_selections"
  end

  class MigrationLlmModel < ActiveRecord::Base
    self.table_name = "llm_models"
  end

  DIRECT_OUTBOUND_RUNNER_KEYS = %w[kilocode opencode pi].freeze
  TIER_MODELS_COMMENT = <<~TEXT.squish.freeze
    Per-tier model map shared by Runner and Provider records on this table.
    Shape: {"low":{"model_id":"model-id","provider_id":123}} keyed by
    LlmModel tiers.
  TEXT

  def up
    add_column :runners, :tier_models, :jsonb, default: {}, null: false, comment: TIER_MODELS_COMMENT

    backfill_model_selection_tiers!
    change_column_null :model_selections, :llm_model_id, true
    add_check_constraint :model_selections, "tier IS NOT NULL", name: "model_selections_tier_not_null", validate: false

    backfill_runner_tier_models!
  end

  def down
    remove_check_constraint :model_selections, name: "model_selections_tier_not_null"

    if MigrationModelSelection.where(llm_model_id: nil).exists?
      raise ActiveRecord::IrreversibleMigration, "Cannot restore NOT NULL llm_model_id with null model_selections rows present"
    end

    change_column_null :model_selections, :llm_model_id, false
    remove_column :runners, :tier_models
  end

  private

  def backfill_model_selection_tiers!
    safety_assured do
      execute <<~SQL.squish
        UPDATE model_selections
        SET tier = llm_models.tier
        FROM llm_models
        WHERE model_selections.llm_model_id = llm_models.id
          AND model_selections.tier IS NULL
      SQL
    end

    return unless MigrationModelSelection.where(tier: nil).exists?

    raise "Cannot enforce NOT NULL on model_selections.tier because some rows still have no tier"
  end

  def backfill_runner_tier_models!
    failures = []

    MigrationRunner.where(runner_key: DIRECT_OUTBOUND_RUNNER_KEYS).find_each do |runner|
      next if runner.tier_models.present?

      model_id = direct_outbound_model_id_for(runner)
      next if model_id.blank?

      model = MigrationLlmModel.find_by(model_id: model_id)
      if model.nil? || model.tier.blank?
        failures << "runner ##{runner.id} (#{runner.runner_key}) missing tiered llm_model #{model_id.inspect}"
        next
      end

      runner.update_columns(
        tier_models: {
          model.tier => {
            "model_id" => model.model_id,
            "provider_id" => runner.id
          }
        }
      )
    end

    return if failures.empty?

    raise "Failed to backfill runners.tier_models: #{failures.join('; ')}"
  end

  def direct_outbound_model_id_for(runner)
    config = runner.config.is_a?(Hash) ? runner.config : {}

    case runner.runner_key
    when "kilocode"
      config.fetch("kilocode", {}).fetch("model", "").to_s.presence
    when "opencode"
      config.fetch("opencode", {}).fetch("model", "").to_s.presence
    when "pi"
      config.fetch("pi", {}).fetch("model", "").to_s.presence
    end
  end
end
