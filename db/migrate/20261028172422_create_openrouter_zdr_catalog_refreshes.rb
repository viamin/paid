# frozen_string_literal: true

class CreateOpenrouterZdrCatalogRefreshes < ActiveRecord::Migration[8.1]
  def change
    create_table :openrouter_zdr_catalog_refreshes do |t|
      t.string :catalog_key
      t.datetime :last_successful_at
      t.datetime :last_attempted_at
      t.text :last_error

      t.timestamps
    end

    add_index :openrouter_zdr_catalog_refreshes, :catalog_key, unique: true
  end
end
