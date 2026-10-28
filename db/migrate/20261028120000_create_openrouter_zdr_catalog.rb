# frozen_string_literal: true

class CreateOpenrouterZdrCatalog < ActiveRecord::Migration[8.1]
  def change
    create_table :openrouter_zdr_syncs do |t|
      t.string :status, null: false, default: "unavailable"
      t.datetime :last_attempted_at
      t.datetime :last_successful_at
      t.integer :models_count, null: false, default: 0
      t.text :error_message
      t.timestamps
    end

    create_table :openrouter_zdr_endpoints do |t|
      t.string :model_id, null: false
      t.string :endpoint_name, null: false
      t.string :provider_name
      t.jsonb :metadata, null: false, default: {}
      t.datetime :last_seen_at, null: false
      t.timestamps
    end

    add_index :openrouter_zdr_endpoints, [ :model_id, :endpoint_name ], unique: true,
      name: "idx_openrouter_zdr_endpoints_identity"
    add_index :openrouter_zdr_endpoints, :model_id
    add_check_constraint :openrouter_zdr_syncs, "status IN ('available', 'unavailable')",
      name: "openrouter_zdr_sync_status"
  end
end
