# frozen_string_literal: true

class AddDiscardedAtToProviders < ActiveRecord::Migration[8.1]
  def change
    add_column :providers, :discarded_at, :datetime, comment: "Soft-delete timestamp so historical provider names remain available for filters and run history."
    add_index :providers, :discarded_at

    remove_index :providers, name: "idx_providers_unique_api_key"
    remove_index :providers, name: "idx_providers_unique_subscription"

    add_index :providers, [ :user_id, :provider_key, :provider_api_key_id, :name ],
      unique: true,
      where: "((auth_type)::text = 'api_key'::text) AND (discarded_at IS NULL)",
      name: "idx_providers_unique_api_key"
    add_index :providers, [ :user_id, :provider_key ],
      unique: true,
      where: "((auth_type)::text = 'subscription'::text) AND (discarded_at IS NULL)",
      name: "idx_providers_unique_subscription"
  end
end
