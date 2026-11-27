# frozen_string_literal: true

# idx_egress_allowlist_entries_project_enabled covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5530 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :egress_allowlist_entries, name: "index_egress_allowlist_entries_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :egress_allowlist_entries, [ :project_id ],
      name: "index_egress_allowlist_entries_on_project_id", algorithm: :concurrently
  end
end
