# frozen_string_literal: true

class RemoveRedundantProviderApiKeysUserIdIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  # @spec POSTGRESQL-PERSISTENCE-030
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
