# frozen_string_literal: true

# index_marketplace_entry_versions_unique_version covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5611 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :marketplace_entry_versions, name: "index_marketplace_entry_versions_on_marketplace_entry_id", algorithm: :concurrently
  end

  def down
    add_index :marketplace_entry_versions, [ :marketplace_entry_id ],
      name: "index_marketplace_entry_versions_on_marketplace_entry_id", algorithm: :concurrently
  end
end
