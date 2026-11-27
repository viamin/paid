# frozen_string_literal: true

# index_account_memberships_on_user_id_and_account_id covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5441 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :account_memberships, name: "index_account_memberships_on_user_id", algorithm: :concurrently
  end

  def down
    add_index :account_memberships, [ :user_id ],
      name: "index_account_memberships_on_user_id", algorithm: :concurrently
  end
end
