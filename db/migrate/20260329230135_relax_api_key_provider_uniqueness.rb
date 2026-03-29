# frozen_string_literal: true

class RelaxApiKeyProviderUniqueness < ActiveRecord::Migration[8.1]
  def change
    remove_index :providers, name: "idx_providers_unique_api_key"

    add_index :providers, [ :user_id, :provider_key, :provider_api_key_id, :name ],
      unique: true,
      where: "auth_type = 'api_key'",
      name: "idx_providers_unique_api_key"
  end
end
