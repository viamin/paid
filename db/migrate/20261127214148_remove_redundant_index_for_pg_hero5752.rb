# frozen_string_literal: true

# idx_partial_closeout_projection_entries_generation covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5752 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :partial_closeout_projection_entries, name: "index_partial_closeout_projection_entries_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :partial_closeout_projection_entries, [ :project_id ],
      name: "index_partial_closeout_projection_entries_on_project_id", algorithm: :concurrently
  end
end
