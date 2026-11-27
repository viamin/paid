# frozen_string_literal: true

# idx_connector_events_account_connector covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5539 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :external_connector_events, name: "index_external_connector_events_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :external_connector_events, [ :account_id ],
      name: "index_external_connector_events_on_account_id", algorithm: :concurrently
  end
end
