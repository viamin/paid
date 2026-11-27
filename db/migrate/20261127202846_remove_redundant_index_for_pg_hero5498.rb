# frozen_string_literal: true

# idx_pool_entries_project_host_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5498 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :container_pool_entries, name: "index_container_pool_entries_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :container_pool_entries, [ :project_id ],
      name: "index_container_pool_entries_on_project_id", algorithm: :concurrently
  end
end
