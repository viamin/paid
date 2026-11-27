# frozen_string_literal: true

# index_account_memberships_on_account_id_and_role covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5440 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :account_memberships, name: "index_account_memberships_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :account_memberships, [ :account_id ],
      name: "index_account_memberships_on_account_id", algorithm: :concurrently
  end
end
