# frozen_string_literal: true

# idx_page_load_measurements_capture_route covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5669 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :page_load_measurements, name: "index_page_load_measurements_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :page_load_measurements, [ :project_id ],
      name: "index_page_load_measurements_on_project_id", algorithm: :concurrently
  end
end
