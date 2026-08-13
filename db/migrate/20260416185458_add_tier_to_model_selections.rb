class AddTierToModelSelections < ActiveRecord::Migration[8.1]
  def change
    add_column :model_selections, :tier, :string, limit: 10
    add_index :model_selections, :tier
    add_check_constraint :model_selections,
      "tier IS NULL OR tier IN ('low', 'mid', 'high')",
      name: "model_selections_tier_check"
  end
end
