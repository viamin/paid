# frozen_string_literal: true

class CreateOpenrouterZdrCatalog < ActiveRecord::Migration[8.1]
  def change
    create_table :openrouter_zdr_catalogs do |t|
      t.string :catalog_key, null: false
      t.datetime :last_attempted_at
      t.datetime :last_successful_at
      t.datetime :unavailable_at
      t.string :unavailability_reason
      t.timestamps
    end
    add_index :openrouter_zdr_catalogs, :catalog_key, unique: true

    create_table :openrouter_zdr_models do |t|
      t.string :model_id, null: false
      t.integer :endpoint_count, null: false, default: 0
      t.jsonb :endpoint_payloads, null: false, default: []
      t.datetime :last_seen_at, null: false
      t.timestamps
    end
    add_index :openrouter_zdr_models, :model_id, unique: true
  end
end
