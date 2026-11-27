# frozen_string_literal: true

# index_inbox_history_events_dedup covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5567 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :inbox_history_events, name: "index_inbox_history_events_on_account_id", algorithm: :concurrently
  end

  def down
    add_index :inbox_history_events, [ :account_id ],
      name: "index_inbox_history_events_on_account_id", algorithm: :concurrently
  end
end
