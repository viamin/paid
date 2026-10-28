# frozen_string_literal: true

class CreateOpenrouterZdrCatalogRefreshes < ActiveRecord::Migration[8.1]
  def change
    create_table :openrouter_zdr_catalog_refreshes do |t|
      t.string :catalog_name, null: false
      t.string :status, null: false, default: "never"
      t.datetime :last_attempted_at
      t.datetime :last_successful_at
      t.datetime :unavailable_at
      t.string :error_class
      t.text :error_message
      t.timestamps
    end

    add_index :openrouter_zdr_catalog_refreshes, :catalog_name, unique: true
  end
end
