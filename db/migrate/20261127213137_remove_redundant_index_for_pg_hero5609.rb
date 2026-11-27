# frozen_string_literal: true

# idx_marketplace_entries_scope covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5609 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :marketplace_entries, name: "index_marketplace_entries_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :marketplace_entries, [ :account_id ],
      name: "index_marketplace_entries_on_account_id", algorithm: :concurrently
  end
end
