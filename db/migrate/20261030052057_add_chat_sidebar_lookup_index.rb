# frozen_string_literal: true

class AddChatSidebarLookupIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :chat_sessions, [ :account_id, :updated_at, :id ],
      order: { updated_at: :desc, id: :desc },
      where: "status <> 'archived'",
      name: "index_chat_sessions_visible_sidebar",
      algorithm: :concurrently
  end
end
