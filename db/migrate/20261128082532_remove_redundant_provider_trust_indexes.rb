# frozen_string_literal: true

class RemoveRedundantProviderTrustIndexes < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-026
  def up
    remove_index :provider_identity_mappings, name: "index_provider_identity_mappings_on_account_id", algorithm: :concurrently, if_exists: true
    remove_index :trusted_provider_identities, name: "index_trusted_provider_identities_on_account_id", algorithm: :concurrently, if_exists: true
  end

  def down
    add_index :provider_identity_mappings, :account_id, algorithm: :concurrently, if_not_exists: true
    add_index :trusted_provider_identities, :account_id, algorithm: :concurrently, if_not_exists: true
  end
end
