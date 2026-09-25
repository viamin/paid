# frozen_string_literal: true

class AddInteractiveInboxAuditToChatSessions < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def up
    return unless table_exists?(:chat_sessions)

    add_inbox_item_key
    add_inbox_item_metadata
    add_opened_at
    add_closed_at
    add_active_inbox_item_index
  end

  def down
    return unless table_exists?(:chat_sessions)

    safety_assured do
      remove_index :chat_sessions,
        name: "index_chat_sessions_active_inbox_item_per_creator",
        algorithm: :concurrently,
        if_exists: true
      remove_column :chat_sessions, :closed_at if column_exists?(:chat_sessions, :closed_at)
      remove_column :chat_sessions, :opened_at if column_exists?(:chat_sessions, :opened_at)
      remove_column :chat_sessions, :inbox_item_metadata if column_exists?(:chat_sessions, :inbox_item_metadata)
      remove_column :chat_sessions, :inbox_item_key if column_exists?(:chat_sessions, :inbox_item_key)
    end
  end

  private

  def add_inbox_item_key
    return if column_exists?(:chat_sessions, :inbox_item_key)

    add_column :chat_sessions, :inbox_item_key, :string,
      comment: "Stable Inbox::Queue entry key that this interactive chat session was opened from."
  end

  def add_inbox_item_metadata
    return if column_exists?(:chat_sessions, :inbox_item_metadata)

    add_column :chat_sessions, :inbox_item_metadata, :jsonb, null: false, default: {},
      comment: "Audit snapshot of the linked inbox item's queue metadata at chat open time."
  end

  def add_opened_at
    return if column_exists?(:chat_sessions, :opened_at)

    add_column :chat_sessions, :opened_at, :datetime,
      comment: "When an interactive inbox chat session was opened."
  end

  def add_closed_at
    return if column_exists?(:chat_sessions, :closed_at)

    add_column :chat_sessions, :closed_at, :datetime,
      comment: "When an interactive inbox chat session was closed or archived."
  end

  def add_active_inbox_item_index
    return if index_exists?(:chat_sessions, [ :created_by_id, :inbox_item_key ], name: "index_chat_sessions_active_inbox_item_per_creator")

    add_index :chat_sessions, [ :created_by_id, :inbox_item_key ],
      unique: true,
      where: "status = 'active' AND inbox_item_key IS NOT NULL",
      name: "index_chat_sessions_active_inbox_item_per_creator",
      algorithm: :concurrently
  end
end
