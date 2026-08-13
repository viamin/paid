# frozen_string_literal: true

class CreateProviderApiKeys < ActiveRecord::Migration[8.1]
  def change
    create_table :provider_api_keys do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, limit: 100, null: false
      t.text :api_key, null: false
      t.jsonb :compatible_providers, default: [], null: false

      t.timestamps
    end

    add_index :provider_api_keys, [ :user_id, :name ], unique: true
  end
end
