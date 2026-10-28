# frozen_string_literal: true

class CreateOpenrouterZdrCatalogStates < ActiveRecord::Migration[8.1]
  def change
    create_table :openrouter_zdr_catalog_states do |t|
      t.string :source, null: false
      t.datetime :last_successful_at
      t.datetime :last_attempted_at
      t.datetime :unavailable_at
      t.text :last_error

      t.timestamps
    end

    add_index :openrouter_zdr_catalog_states, :source, unique: true
  end
end
