# frozen_string_literal: true

# idx_egress_allowlist_entries_account_project_scope covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5529 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :egress_allowlist_entries, name: "index_egress_allowlist_entries_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :egress_allowlist_entries, [ :account_id ],
      name: "index_egress_allowlist_entries_on_account_id", algorithm: :concurrently
  end
end
