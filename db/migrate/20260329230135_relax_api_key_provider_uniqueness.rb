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
    if duplicate_api_key_provider_entries_exist?
      raise ActiveRecord::IrreversibleMigration,
        "Cannot restore the original API-key provider uniqueness while duplicate provider entries exist for the same user, provider, and API key."
    end

    remove_index :providers, name: "idx_providers_unique_api_key"

    change_column_null :providers, :name, true
    change_column_default :providers, :name, from: "", to: nil

    execute <<~SQL.squish
      UPDATE providers
      SET name = NULL
      WHERE name = ''
    SQL

    add_index :providers, [ :user_id, :provider_key, :provider_api_key_id ],
      unique: true,
      where: "auth_type = 'api_key'",
      name: "idx_providers_unique_api_key"
  end

  private

  def duplicate_api_key_provider_entries_exist?
    select_value(<<~SQL.squish).present?
      SELECT 1
      FROM providers
      WHERE auth_type = 'api_key'
      GROUP BY user_id, provider_key, provider_api_key_id
      HAVING COUNT(*) > 1
      LIMIT 1
    SQL
  end
end
