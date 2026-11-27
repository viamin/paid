# frozen_string_literal: true

# idx_on_chat_turn_id_occurred_at_87ddf0bbe7 covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5487 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :chat_turn_lifecycle_events, name: "index_chat_turn_lifecycle_events_on_chat_turn_id", algorithm: :concurrently
  end

  def down
    add_index :chat_turn_lifecycle_events, [ :chat_turn_id ],
      name: "index_chat_turn_lifecycle_events_on_chat_turn_id", algorithm: :concurrently
  end
end
