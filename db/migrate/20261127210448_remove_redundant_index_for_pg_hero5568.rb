# frozen_string_literal: true

# index_inbox_removals_on_project_id_and_responsible_phase covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5568 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :inbox_removals, name: "index_inbox_removals_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :inbox_removals, [ :project_id ],
      name: "index_inbox_removals_on_project_id", algorithm: :concurrently
  end
end
