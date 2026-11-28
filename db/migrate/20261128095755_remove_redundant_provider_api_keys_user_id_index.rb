# frozen_string_literal: true

class RemoveRedundantProviderApiKeysUserIdIndex < ActiveRecord::Migration[8.1]
  # @spec POSTGRESQL-PERSISTENCE-014
  disable_ddl_transaction!

  def up
    remove_index :provider_api_keys,
      name: "index_provider_api_keys_on_user_id",
      algorithm: :concurrently
  end

  def down
    add_index :provider_api_keys,
      :user_id,
      name: "index_provider_api_keys_on_user_id",
      algorithm: :concurrently
  end
end
