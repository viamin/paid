# frozen_string_literal: true

# idx_connector_events_project_external_id covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5541 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :external_connector_events, name: "index_external_connector_events_on_project_id", algorithm: :concurrently
  end

  def down
    add_index :external_connector_events, [ :project_id ],
      name: "index_external_connector_events_on_project_id", algorithm: :concurrently
  end
end
