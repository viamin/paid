# frozen_string_literal: true

# index_marketplace_entry_rules_unique_mode covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5610 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :marketplace_entry_rules, name: "index_marketplace_entry_rules_on_marketplace_entry_id", algorithm: :concurrently
  end

  def down
    add_index :marketplace_entry_rules, [ :marketplace_entry_id ],
      name: "index_marketplace_entry_rules_on_marketplace_entry_id", algorithm: :concurrently
  end
end
