class AddTierModelIdsToProviders < ActiveRecord::Migration[8.1]
  def change
    add_column :providers, :tier_model_ids, :jsonb, default: {}, null: false
    add_index :providers, :tier_model_ids, using: :gin
  end
end
