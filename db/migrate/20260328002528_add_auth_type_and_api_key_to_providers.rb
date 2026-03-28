# frozen_string_literal: true

class AddAuthTypeAndApiKeyToProviders < ActiveRecord::Migration[8.1]
  def change
    add_column :providers, :auth_type, :string, limit: 20, default: "subscription", null: false
    add_column :providers, :name, :string, limit: 100
    add_column :providers, :fallback_role, :string, limit: 30, default: "standard", null: false
    add_reference :providers, :provider_api_key, null: true,
      foreign_key: { on_delete: :nullify }

    # Replace the old unique index with partial indexes that allow multiple
    # entries per provider_key as long as they differ by auth_type/api_key.
    remove_index :providers, [:user_id, :provider_key], unique: true

    # One subscription entry per provider per user
    add_index :providers, [:user_id, :provider_key],
      unique: true,
      where: "auth_type = 'subscription'",
      name: "idx_providers_unique_subscription"

    # One API key entry per provider per API key per user
    add_index :providers, [:user_id, :provider_key, :provider_api_key_id],
      unique: true,
      where: "auth_type = 'api_key'",
      name: "idx_providers_unique_api_key"

    add_index :providers, :auth_type
  end
end
