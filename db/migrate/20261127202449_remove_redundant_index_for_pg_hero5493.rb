# frozen_string_literal: true

# index_config_bundles_on_project_status covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5493 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :configuration_bundles, name: "index_configuration_bundles_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :configuration_bundles, [ :project_id ],
      name: "index_configuration_bundles_on_project_id", algorithm: :concurrently
  end
end
