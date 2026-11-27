# frozen_string_literal: true

# index_collector_runs_on_project_version_id_and_collector_type covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5491 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :collector_runs, name: "index_collector_runs_on_project_version_id", algorithm: :concurrently
  end

  def down
    add_index :collector_runs, [ :project_version_id ],
      name: "index_collector_runs_on_project_version_id", algorithm: :concurrently
  end
end
