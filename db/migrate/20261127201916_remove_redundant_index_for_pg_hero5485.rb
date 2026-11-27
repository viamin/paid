# frozen_string_literal: true

# index_chat_messages_on_chat_session_id_and_created_at covers the removed index's leading columns.
# @spec POSTGRESQL-PERSISTENCE-022
class RemoveRedundantIndexForPgHero5485 < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    remove_index :chat_messages, name: "index_chat_messages_on_chat_session_id", algorithm: :concurrently
  end

  def down
    add_index :chat_messages, [ :chat_session_id ],
      name: "index_chat_messages_on_chat_session_id", algorithm: :concurrently
  end
end
