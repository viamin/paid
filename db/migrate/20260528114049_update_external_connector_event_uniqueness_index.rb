# frozen_string_literal: true

class UpdateExternalConnectorEventUniquenessIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :external_connector_events, name: "idx_connector_events_project_external_id", algorithm: :concurrently
    add_index :external_connector_events, [ :project_id, :connector_key, :external_event_id ],
      unique: true,
      name: "idx_connector_events_project_external_id",
      algorithm: :concurrently
  end

  def down
    remove_index :external_connector_events, name: "idx_connector_events_project_external_id", algorithm: :concurrently
    add_index :external_connector_events, [ :project_id, :external_event_id ],
      unique: true,
      name: "idx_connector_events_project_external_id",
      algorithm: :concurrently
  end
end
