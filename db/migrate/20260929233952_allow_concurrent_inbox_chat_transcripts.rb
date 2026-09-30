# frozen_string_literal: true

class AllowConcurrentInboxChatTranscripts < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :chat_sessions, [ :created_by_id, :inbox_item_key, :status ],
      name: "index_chat_sessions_inbox_history", where: "inbox_item_key IS NOT NULL",
      algorithm: :concurrently
    remove_index :chat_sessions, [ :created_by_id, :inbox_item_key ],
      name: "index_chat_sessions_active_inbox_item_per_creator", unique: true,
      where: "status = 'active' AND inbox_item_key IS NOT NULL", algorithm: :concurrently
  end
end
