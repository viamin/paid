# frozen_string_literal: true

# index_apple_worker_profiles_on_account_id_and_name covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5467 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :apple_worker_profiles, name: "index_apple_worker_profiles_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :apple_worker_profiles, [ :account_id ],
      name: "index_apple_worker_profiles_on_account_id", algorithm: :concurrently
  end
end
