class CreateOpenrouterZdrCatalog < ActiveRecord::Migration[8.1]
  def change
    create_table :openrouter_zdr_catalog_statuses do |t|
      t.string :catalog_key, null: false
      t.string :status, null: false, default: "unavailable"
      t.datetime :last_attempted_at
      t.datetime :last_successful_at
      t.string :last_error
      t.timestamps
    end
    add_index :openrouter_zdr_catalog_statuses, :catalog_key, unique: true

    create_table :openrouter_zdr_eligibilities do |t|
      t.string :model_id, null: false
      t.jsonb :endpoint_metadata, null: false, default: {}
      t.integer :endpoint_count, null: false, default: 0
      t.boolean :active, null: false, default: true
      t.datetime :last_seen_at, null: false
      t.timestamps
    end
    add_index :openrouter_zdr_eligibilities, :model_id, unique: true
    add_index :openrouter_zdr_eligibilities, :active
  end
end
