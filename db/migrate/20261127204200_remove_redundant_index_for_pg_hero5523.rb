# frozen_string_literal: true

# index_design_amendments_on_project_id_and_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5523 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :design_amendments, name: "index_design_amendments_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :design_amendments, [ :project_id ],
      name: "index_design_amendments_on_project_id", algorithm: :concurrently
  end
end
