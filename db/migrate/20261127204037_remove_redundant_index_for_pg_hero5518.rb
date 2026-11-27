# frozen_string_literal: true

# index_design_amendment_pauses_unique_branch covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5518 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :design_amendment_pauses, name: "index_design_amendment_pauses_on_design_amendment_id", algorithm: :concurrently
  end

  def down
    add_index :design_amendment_pauses, [ :design_amendment_id ],
      name: "index_design_amendment_pauses_on_design_amendment_id", algorithm: :concurrently
  end
end
