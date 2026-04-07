class AddTierToLlmModels < ActiveRecord::Migration[8.1]
  def change
    add_column :llm_models, :tier, :string, limit: 10
    add_index :llm_models, :tier
    add_check_constraint :llm_models,
      "tier IS NULL OR tier IN ('low', 'mid', 'high')",
      name: "llm_models_tier_check"
  end
end
