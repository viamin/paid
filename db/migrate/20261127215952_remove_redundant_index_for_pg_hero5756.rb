# frozen_string_literal: true

# index_project_baselines_on_project_id_and_metric_name covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5756 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :project_baselines, name: "index_project_baselines_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :project_baselines, [ :project_id ],
      name: "index_project_baselines_on_project_id", algorithm: :concurrently
  end
end
