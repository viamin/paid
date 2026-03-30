# frozen_string_literal: true

class RelaxApiKeyProviderUniqueness < ActiveRecord::Migration[8.1]
  def up
    remove_index :providers, name: "idx_providers_unique_api_key"

    execute <<~SQL.squish
      UPDATE providers
      SET name = ''
      WHERE name IS NULL
    SQL

    change_column_default :providers, :name, from: nil, to: ""
    change_column_null :providers, :name, false, ""

    add_index :providers, [ :user_id, :provider_key, :provider_api_key_id, :name ],
      unique: true,
      where: "auth_type = 'api_key'",
      name: "idx_providers_unique_api_key"
  end

  def down
    remove_index :providers, name: "idx_providers_unique_api_key"

    change_column_null :providers, :name, true
    change_column_default :providers, :name, from: "", to: nil

    add_index :providers, [ :user_id, :provider_key, :provider_api_key_id, :name ],
      unique: true,
      where: "auth_type = 'api_key'",
      name: "idx_providers_unique_api_key"
  end
end
